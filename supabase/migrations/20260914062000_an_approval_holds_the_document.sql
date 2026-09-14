-- An approval holds the document.
--
-- A static walk through every persona (14 September) found three controls a
-- customer or an auditor would expect and the product did not keep. Each was
-- checked against the functions as they stand after every patch before this
-- file was written, and each was true.
--
--   1. An approval did not hold anything. Submitting a purchase order or a
--      sales order opens an approval request, whose tasks go to the approving
--      role (erp.execute_effects' require_approval, 20260906100000;
--      erp.request_approval and erp.open_approval_seq, 20260831202427). When
--      the last task is approved the request reads approved, and that is all:
--      nothing moves the document, and the 'approve' transition asked only
--      for its permission (erp.perform_transition). A holder of
--      procurement.approve approved an order whose tasks were pending, or
--      refused, and the build's own procurement suite did exactly that while
--      the finance step was still open. The only place an approval's state was
--      read was the platform's quote (erp.approve_quote).
--
--   2. Whoever asked could approve. erp.step_approvers is every holder of the
--      step's role, so the person submitting got a task on their own order
--      whenever they held the role, and decided it; erp.decide_approval_task
--      asked only whether the task was theirs. With nobody else holding the
--      role, the order was approved by its author alone. With nobody at all
--      holding it, the submit was refused (APPROVAL_STEP_UNSTAFFED), which is
--      right and stays.
--
--   3. The installers route every step to 'administrator', and the doors the
--      Configuration screen calls could not say otherwise:
--      public.erp_configure_procurement(bigint) and
--      public.erp_configure_sales(numeric) passed only a threshold.
--
--   And a goods receipt could be taken against any purchase order line —
--   a draft, one waiting on its approval, one approved and never sent
--   (erp.receive_against read no state), and the desk's picker offered them.
--
-- What this file does, in order:
--
--   1. The hold. erp.require_document_approval(document, transition) runs
--      inside erp.transition_document after the transition is found and
--      authorised. For 'approve' on a document whose type names an approval
--      chain and which has an approval request, it refuses while that request
--      is pending (CLOVEERP_DOCUMENT_APPROVAL_PENDING) or refused
--      (CLOVEERP_DOCUMENT_APPROVAL_REJECTED). The request that counts is the
--      pending one if there is one, else the newest (an approved one on a
--      tie). A document whose type has no chain, or that was submitted before
--      its type had one and so has no request, approves as it always did.
--
--   2. Maker and checker. Once the organisation is live, the person who asked
--      for a document's approval neither approves a task on it
--      (erp.decide_approval_task) nor performs its 'approve' transition
--      (CLOVEERP_DOCUMENT_SELF_APPROVAL). The transition is refused only when
--      somebody was actually asked: a request no step applied to approved
--      itself, nobody's judgement was needed, and the person who submitted may
--      carry on (a quote within its discount threshold, 20260904600000).
--      erp.open_approval_seq no longer asks the person who asked, nor a
--      delegate acting for them. Where that leaves a step with nobody, a live
--      organisation refuses the submission by name
--      (CLOVEERP_APPROVAL_NO_OTHER_APPROVER); an organisation not yet live
--      asks the one person it has, as a change set's author may approve their
--      own before go-live (20260829320000). A demonstration is never live.
--      Document requests only: a match exception, a margin exception, a count
--      or a change request keeps its own rules, which are other work.
--
--   3. Receiving. erp.receive_against refuses a line on a purchase order that
--      is not sent or partially received (CLOVEERP_ORDER_NOT_SENT), after the
--      order's behaviour is read, so a drop-ship line and a consigned receipt
--      are still refused for what they are. public.erp_document_lines gains
--      p_document_states, the line door's counterpart of erp_documents'
--      p_states (20260914050000), so the desk's receiving picker offers only
--      lines on orders that can be received against.
--
--   4. Approvers are operational roles. public.erp_configure_procurement and
--      public.erp_configure_sales take p_approver_role. Named, it must be one
--      of the organisation's active roles (CLOVEERP_APPROVER_ROLE_UNKNOWN).
--      Left out, erp.approver_role_for() takes procurement_manager or
--      sales_manager where the organisation has that role and somebody holds
--      it today, and administrator otherwise: a role nobody holds would refuse
--      every submission until somebody was given it. The erp.* installers keep
--      their own defaults, which the demonstration and the suites name. The
--      base pack's third value bands named administrator, which the pack's own
--      role notes say approves nothing; they name finance_manager. Pack items
--      are edited in place at their version (every pack migration since
--      20260903150000 has), and an organisation that applied the pack keeps
--      the bands it was given.
--
--   5. The demonstration decides its own tasks before approving
--      (erp.approve_my_document_tasks), and the suites that approved a
--      document straight after submitting, or received against an order that
--      was never sent, are adapted: erp_test.approve_document() decides a
--      document's tasks as the people they are assigned to and approves it as
--      somebody allowed to. Every change is a counted replace, as
--      20260912190000 patched the demonstration.
--
-- Proof: erp_test.approval_hold_suite(), sixteen cases, pinned by its wrapper.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The hold
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.require_document_approval(p_document_id uuid, p_transition_code text)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_chain   text;
  v_number  text;
  q         erp.approval_request%rowtype;
  v_waiting integer;
begin
  if p_transition_code is distinct from 'approve' then
    return;
  end if;

  select dt.approval_chain_code, d.document_number
    into v_chain, v_number
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and d.id = p_document_id;

  -- A type with no chain approves on its permission, as it always has.
  if v_chain is null then
    return;
  end if;

  -- The request that governs: the pending one while there is one, otherwise
  -- the newest. Requests opened in one transaction share a timestamp, and an
  -- approved one is preferred on a tie.
  select ar.* into q
    from erp.approval_request ar
   where ar.tenant_id = v_tenant
     and ar.object_type = 'document'
     and ar.object_id = p_document_id
     and ar.status in ('pending', 'approved', 'rejected')
   order by (ar.status = 'pending') desc, ar.requested_at desc, (ar.status = 'approved') desc
   limit 1;

  -- Submitted before its type had a chain: nothing was asked, nothing holds it.
  if not found then
    return;
  end if;

  if q.status = 'pending' then
    select count(*) into v_waiting
      from erp.approval_task t
     where t.tenant_id = v_tenant and t.approval_request_id = q.id and t.status = 'pending';
    raise exception 'CLOVEERP_DOCUMENT_APPROVAL_PENDING: % is waiting on % approval task(s), and is approved once they are decided',
      coalesce(v_number, p_document_id::text), v_waiting
      using errcode = '23514',
            hint = 'The people asked decide their tasks under My approvals. Approve the document once they have.';
  end if;

  if q.status = 'rejected' then
    raise exception 'CLOVEERP_DOCUMENT_APPROVAL_REJECTED: the approval asked for on % was refused',
      coalesce(v_number, p_document_id::text)
      using errcode = '23514',
            hint = 'Send it back to draft, change what was refused, and submit it again.';
  end if;

  -- Approved. Whoever asked does not approve it themselves once the
  -- organisation is live — unless nobody was asked at all, because no step
  -- applied and the request approved itself.
  if q.requested_by = erp.current_principal_id()
     and erp.tenant_is_live(v_tenant)
     and exists (select 1 from erp.approval_task t
                  where t.tenant_id = v_tenant and t.approval_request_id = q.id
                    and t.status <> 'skipped') then
    raise exception 'CLOVEERP_DOCUMENT_SELF_APPROVAL: you asked for this approval, so somebody else gives it'
      using errcode = '42501',
            hint = 'Another holder of the approving role decides the task. Give that role to a second person if there is nobody else.';
  end if;
end;
$$;

comment on function erp.require_document_approval(uuid, text) is
  'Refuses the approve transition on a document whose type names an approval '
  'chain while its approval request is pending or refused, and, once the '
  'organisation is live, refuses it to the person who asked for an approval '
  'somebody else was asked to give. Called by erp.transition_document after '
  'the transition is found and authorised. A type with no chain, or a document '
  'with no request, is not held.';

revoke all on function erp.require_document_approval(uuid, text) from public, anon, authenticated;

-- The transition asks, and a task names nobody who asked.

do $patch$
declare
  v_def text := pg_get_functiondef('erp.transition_document(uuid,text,text)'::regprocedure);
  v_old text := $p$  v_to := erp.perform_transition('document', p_document_id, p_transition_code,
                                 v_ctx, p_reason);
$p$;
  v_new text := $q$  v_to := erp.perform_transition('document', p_document_id, p_transition_code,
                                 v_ctx, p_reason);

  -- An approval holds the document (20260914062000). Asked after the
  -- transition has been found and authorised, so a person who may not approve
  -- is told that first; the move is undone with the refusal.
  perform erp.require_document_approval(p_document_id, p_transition_code);
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp.transition_document(uuid,text,text) is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp.decide_approval_task(uuid,boolean,text)'::regprocedure);
  v_old text := $p$  update erp.approval_task
     set status = case when p_approve then 'approved' else 'rejected' end::erp.approval_task_status,
$p$;
  v_new text := $q$  -- Whoever asked for a document's approval does not give it, once the
  -- organisation is live (20260914062000). A task can still name them: one
  -- raised before that rule, or reached through a delegation. Refusing the
  -- request stays open to them, which only sends the document back.
  if p_approve
     and v_req.object_type = 'document'
     and v_req.requested_by = v_actor
     and erp.tenant_is_live(v_tenant) then
    raise exception 'CLOVEERP_DOCUMENT_SELF_APPROVAL: you asked for this approval, so somebody else gives it'
      using errcode = '42501',
            hint = 'Another holder of the approving role decides the task. Give that role to a second person if there is nobody else.';
  end if;

  update erp.approval_task
     set status = case when p_approve then 'approved' else 'rejected' end::erp.approval_task_status,
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp.decide_approval_task(uuid,boolean,text) is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Who is asked
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Restated whole: nothing has patched it since 20260831202427, and the change
-- is inside the statement that raises the tasks. The loop, the skipped steps
-- and the unstaffed refusal are as they were.

create or replace function erp.open_approval_seq(p_request_id uuid, p_after_seq integer)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_req     erp.approval_request%rowtype;
  v_seq     integer;
  v_made    integer;
  v_exclude uuid;
  v_role    text;
  st        record;
begin
  select * into v_req from erp.approval_request where tenant_id = v_tenant and id = p_request_id;

  -- Whoever asks for a document's approval is not asked to give it
  -- (20260914062000), and neither is anybody acting for them.
  v_exclude := case when v_req.object_type = 'document' then v_req.requested_by end;

  loop
    select min(s.seq) into v_seq
      from erp.approval_step s
     where s.tenant_id = v_tenant
       and s.approval_chain_version_id = v_req.approval_chain_version_id
       and (p_after_seq is null or s.seq > p_after_seq);

    exit when v_seq is null;

    v_made := 0;

    for st in
      select s.* from erp.approval_step s
       where s.tenant_id = v_tenant
         and s.approval_chain_version_id = v_req.approval_chain_version_id
         and s.seq = v_seq
       order by s.code
    loop
      -- A conditional step that does not apply is recorded as skipped rather
      -- than omitted, so the audit shows it was considered.
      if not erp.jsonlogic_bool(st.condition, v_req.context) then
        insert into erp.approval_task (
          tenant_id, approval_request_id, approval_step_id, step_code, seq, status)
        values (v_tenant, p_request_id, st.id, st.code, st.seq, 'skipped');
        continue;
      end if;

      insert into erp.approval_task (
        tenant_id, approval_request_id, approval_step_id, step_code, seq,
        assignee_user_id, assignee_role_id, delegated_from, due_at)
      select v_tenant, p_request_id, st.id, st.code, st.seq,
             a.app_user_id,
             case when st.approver_kind = 'role' then st.role_id end,
             a.delegated_from,
             case when st.escalate_after is not null then now() + st.escalate_after end
        from erp.step_approvers(st.id, v_req.object_type, v_req.entity_id, v_req.site_id) a
       where v_exclude is null
          or (a.app_user_id <> v_exclude and a.delegated_from is distinct from v_exclude);

      get diagnostics v_made = row_count;

      -- Nobody left but the person who asked.
      if v_made = 0 and v_exclude is not null
         and exists (select 1
                       from erp.step_approvers(st.id, v_req.object_type, v_req.entity_id, v_req.site_id) a
                      where a.app_user_id = v_exclude or a.delegated_from = v_exclude) then
        if erp.tenant_is_live(v_tenant) then
          select r.code into v_role from erp.role r where r.tenant_id = v_tenant and r.id = st.role_id;
          raise exception 'CLOVEERP_APPROVAL_NO_OTHER_APPROVER: step % needs somebody other than the person asking, and nobody else holds %',
            st.code, coalesce(v_role, 'the approver it names')
            using errcode = '23514',
                  hint = 'Give the approving role to a second person, or choose another approver role for these documents on the Configuration screen.';
        end if;

        -- Not yet live, there may be nobody else to ask: the person asking is
        -- asked, as a change set's author approves their own before go-live.
        insert into erp.approval_task (
          tenant_id, approval_request_id, approval_step_id, step_code, seq,
          assignee_user_id, assignee_role_id, delegated_from, due_at)
        select v_tenant, p_request_id, st.id, st.code, st.seq,
               a.app_user_id,
               case when st.approver_kind = 'role' then st.role_id end,
               a.delegated_from,
               case when st.escalate_after is not null then now() + st.escalate_after end
          from erp.step_approvers(st.id, v_req.object_type, v_req.entity_id, v_req.site_id) a;

        get diagnostics v_made = row_count;
      end if;

      if v_made = 0 then
        -- A step whose role has nobody in it would silently stall the request.
        raise exception
          'CLOVEERP_APPROVAL_STEP_UNSTAFFED: step % has no eligible approver in scope',
          st.code using errcode = '23514',
          hint = 'Give the approving role to somebody, or choose another approver role for these documents on the Configuration screen.';
      end if;
    end loop;

    -- If every step at this sequence was skipped, move on to the next.
    if exists (select 1 from erp.approval_task t
                where t.tenant_id = v_tenant
                  and t.approval_request_id = p_request_id
                  and t.seq = v_seq
                  and t.status = 'pending') then
      update erp.approval_request set current_seq = v_seq, updated_at = now()
       where id = p_request_id;
      return v_seq;
    end if;

    p_after_seq := v_seq;
  end loop;

  return null;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Goods are received against an order that was sent
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.receive_against reads the order's state, after its behaviour. The line
-- door is restated as 20260914050000 wrote it, with p_document_states after
-- p_open_only, so the receiving picker can ask for sent orders only. Dropped
-- rather than overloaded, for the reason given there. An empty list lists
-- nothing; a document with no lifecycle is in no state.

do $patch$
declare
  v_def text := pg_get_functiondef('erp.receive_against(uuid,uuid,numeric,uuid)'::regprocedure);
  v_old text := $p$  -- Tolerance is measured against what is still open, not against the whole
$p$;
  v_new text := $q$  -- 20260914062000: goods are received against a purchase order that has been
  -- sent to the supplier. A draft, an order still waiting on its approval, or
  -- one approved and never sent has promised nobody anything, and receiving
  -- against it books stock and an accrual that nobody agreed to. An order
  -- received in full takes no more. Asked after the order's behaviour, so a
  -- drop-ship line and a consigned receipt are refused for what they are.
  if exists (select 1 from erp.document_type odt
              where odt.tenant_id = v_tenant and odt.id = od.document_type_id
                and odt.base_type_code = 'purchase_order')
     and coalesce((select os.code
                     from erp.object_state ost
                     join erp.state os on os.id = ost.current_state_id
                    where ost.tenant_id = v_tenant and ost.object_type = 'document'
                      and ost.object_id = od.id), '') not in ('sent', 'partially_received') then
    raise exception 'CLOVEERP_ORDER_NOT_SENT: % is %, and goods are received only against an order sent to the supplier',
      od.document_number,
      coalesce((select os.name
                  from erp.object_state ost
                  join erp.state os on os.id = ost.current_state_id
                 where ost.tenant_id = v_tenant and ost.object_type = 'document'
                   and ost.object_id = od.id), 'not started')
      using errcode = '23514',
            hint = 'Have the order approved and send it to the supplier first. An order already received in full takes no more.';
  end if;

  -- Tolerance is measured against what is still open, not against the whole
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp.receive_against(uuid,uuid,numeric,uuid) is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

drop function public.erp_document_lines(uuid, text, integer, boolean);

create function public.erp_document_lines(
  p_document_id     uuid    default null,
  p_type_code       text    default null,
  p_limit           integer default 200,
  p_open_only       boolean default false,
  p_document_states text[]  default null
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x->>'document_number', (x->>'line_no')::int), '[]'::jsonb) from (
    select jsonb_build_object(
             'line_id', dl.id, 'document_id', d.id, 'document_number', d.document_number,
             'document_type', dt.code, 'line_no', dl.line_no,
             'item', i.code, 'description', dl.description,
             'quantity', dl.quantity, 'quantity_fulfilled', dl.quantity_fulfilled,
             'unit_price_minor', dl.unit_price_minor, 'currency', dl.currency,
             'line_state', dl.line_state) as x
      from erp.document_line dl
      join erp.document d on d.tenant_id = dl.tenant_id and d.id = dl.document_id
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      left join erp.item i on i.tenant_id = dl.tenant_id and i.id = dl.item_id
      left join erp.object_state os
        on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      left join erp.state s on s.id = os.current_state_id
     where dl.tenant_id = erp.current_tenant_id()
       and coalesce(dl.is_cancelled, false) = false
       and (p_document_id is null or dl.document_id = p_document_id)
       and (p_type_code is null or dt.code = p_type_code)
       -- Open: its document can still move, and the line is not both received
       -- and invoiced in full.
       and (not coalesce(p_open_only, false)
            or (not (d.is_cancelled or coalesce(s.code = 'cancelled', false))
                and not coalesce(s.is_terminal, false)
                and not (dl.quantity > 0
                         and dl.quantity_fulfilled >= dl.quantity
                         and dl.quantity_invoiced >= dl.quantity)))
       -- Asked for states: the line's document is in one of them.
       and (p_document_states is null or coalesce(s.code = any (p_document_states), false))
     order by d.document_date desc nulls last, dl.line_no
     limit greatest(p_limit, 1)) t;
$$;

comment on function public.erp_document_lines(uuid, text, integer, boolean, text[]) is
  'Lines of the organisation''s documents, optionally of one document or one '
  'type; a cancelled line is never listed. p_open_only leaves out a line whose '
  'document is cancelled or in a terminal state, and a line already received '
  'and invoiced in full. p_document_states lists only lines whose document is '
  'in one of those states; an empty list lists nothing. Reads under row '
  'security as the caller, and authorises nothing.';

revoke all on function public.erp_document_lines(uuid, text, integer, boolean, text[]) from public, anon;
grant execute on function public.erp_document_lines(uuid, text, integer, boolean, text[]) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Approvers are operational roles
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.approver_role_for(p_role text, p_preferred text)
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_role   text := nullif(btrim(p_role), '');
begin
  if v_role is not null then
    if not exists (select 1 from erp.role r
                    where r.tenant_id = v_tenant and r.code = v_role
                      and r.status = 'active') then
      raise exception 'CLOVEERP_APPROVER_ROLE_UNKNOWN: this organisation has no active role %', v_role
        using errcode = '23503',
              hint = 'Choose one of the organisation''s roles, or leave the approver role empty for the default.';
    end if;
    return v_role;
  end if;

  -- The operational role, where the organisation has it and somebody holds it
  -- today. A role nobody holds would refuse every submission until somebody
  -- was given it.
  if p_preferred is not null
     and exists (select 1
                   from erp.role r
                   join erp.user_role ur on ur.tenant_id = r.tenant_id and ur.role_id = r.id
                  where r.tenant_id = v_tenant and r.code = p_preferred and r.status = 'active'
                    and ur.valid_from <= current_date
                    and (ur.valid_to is null or ur.valid_to >= current_date)) then
    return p_preferred;
  end if;

  return 'administrator';
end;
$$;

comment on function erp.approver_role_for(text, text) is
  'The role an installer routes approvals to. A named role must be one of the '
  'organisation''s active roles. With none named: the preferred role where the '
  'organisation has it and somebody holds it today, and administrator otherwise.';

revoke all on function erp.approver_role_for(text, text) from public, anon, authenticated;

drop function public.erp_configure_procurement(bigint);

create function public.erp_configure_procurement(
  p_approval_threshold_minor bigint default 1000000,
  p_approver_role            text   default null
) returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select jsonb_build_object('change_set_id',
    erp.configure_procurement(p_approval_threshold_minor,
                              erp.approver_role_for(p_approver_role, 'procurement_manager')))
$$;

comment on function public.erp_configure_procurement(bigint, text) is
  'Installs the requisition, purchase order and goods receipt lifecycles and '
  'the purchase order approval chain through a change. p_approver_role names '
  'the role asked to approve; left empty, procurement_manager where somebody '
  'holds it, and administrator otherwise.';

revoke all on function public.erp_configure_procurement(bigint, text) from public, anon;
grant execute on function public.erp_configure_procurement(bigint, text) to authenticated, service_role;

drop function public.erp_configure_sales(numeric);

create function public.erp_configure_sales(
  p_discount_threshold_pct numeric default 15,
  p_approver_role          text    default null
) returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select jsonb_build_object('change_set_id',
    erp.configure_sales(p_discount_threshold_pct,
                        erp.approver_role_for(p_approver_role, 'sales_manager')))
$$;

comment on function public.erp_configure_sales(numeric, text) is
  'Installs the quotation, sales order, delivery and sales invoice lifecycles '
  'and the sales order approval chain through a change. p_approver_role names '
  'the role asked to approve; left empty, sales_manager where somebody holds '
  'it, and administrator otherwise.';

revoke all on function public.erp_configure_sales(numeric, text) from public, anon;
grant execute on function public.erp_configure_sales(numeric, text) to authenticated, service_role;

-- The base pack's third bands. The pack's own note on administrator is that it
-- sets the system up and approves nothing.
do $bands$
declare
  v_moved integer;
begin
  update erp_ref.pack_item
     set payload = jsonb_set(payload, '{approver_role}', '"finance_manager"'::jsonb)
   where pack_code = 'base'
     and object_kind = 'approval_band'
     and object_key in ('PROC|requisition|3', 'PROC|purchase_order|3', 'FIN|invoice_reference|3')
     and payload ->> 'approver_role' = 'administrator';
  get diagnostics v_moved = row_count;
  if v_moved <> 3 then
    raise exception 'CLOVEERP_PACK_UNRECOGNISED: % of the base pack''s three administrator bands were moved', v_moved;
  end if;
end
$bands$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The demonstration decides its own tasks
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.approve_my_document_tasks(p_document_id uuid, p_comment text default null)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_me     uuid := erp.current_principal_id();
  v_task   uuid;
  v_n      integer := 0;
begin
  -- Each decision can open the next step, so the tasks are read one at a time.
  loop
    select t.id into v_task
      from erp.approval_task t
      join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
     where t.tenant_id = v_tenant
       and q.object_type = 'document'
       and q.object_id = p_document_id
       and q.status = 'pending'
       and t.status = 'pending'
       and t.assignee_user_id = v_me
     order by t.seq, t.id
     limit 1;

    exit when v_task is null;

    perform erp.decide_approval_task(v_task, true, p_comment);
    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;

comment on function erp.approve_my_document_tasks(uuid, text) is
  'Approves every task on a document''s pending approval that is assigned to '
  'the caller, step after step as each opens, and returns how many. Every '
  'decision goes through erp.decide_approval_task and its rules. Used by the '
  'demonstration builders, whose one person is the approver.';

revoke all on function erp.approve_my_document_tasks(uuid, text) from public, anon, authenticated;

-- The two demonstration builders decide the order's tasks before approving it.

do $patch$
declare
  v_def text := pg_get_functiondef('erp.seed_demo_history(date,date,numeric)'::regprocedure);
  v_old text := $p$    perform erp.transition_document(v_doc, 'submit', 'demonstration');
    perform erp.transition_document(v_doc, 'approve', 'demonstration');
    perform erp.transition_document(v_doc, 'send', 'demonstration');
$p$;
  v_new text := $q$    perform erp.transition_document(v_doc, 'submit', 'demonstration');
    -- The order waits on its approval (20260914062000). A demonstration is
    -- never live and its one person is its approver.
    perform erp.approve_my_document_tasks(v_doc, 'demonstration');
    perform erp.transition_document(v_doc, 'approve', 'demonstration');
    perform erp.transition_document(v_doc, 'send', 'demonstration');
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp.seed_demo_history(date,date,numeric) is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp.seed_demo_history(date,date,numeric)'::regprocedure);
  v_old text := $p$    perform erp.transition_document(v_doc, 'approve', 'demonstration');
    if v_recent and v_date > v_to - 10 and v_roll < 0.22 then
$p$;
  v_new text := $q$    perform erp.approve_my_document_tasks(v_doc, 'demonstration');
    perform erp.transition_document(v_doc, 'approve', 'demonstration');
    if v_recent and v_date > v_to - 10 and v_roll < 0.22 then
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp.seed_demo_history(date,date,numeric) is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp.seed_demo_operations()'::regprocedure);
  v_old text := $p$      perform erp.transition_document(v_po, 'submit');
      perform erp.transition_document(v_po, 'approve');
$p$;
  v_new text := $q$      perform erp.transition_document(v_po, 'submit');
      perform erp.approve_my_document_tasks(v_po, 'demonstration');
      perform erp.transition_document(v_po, 'approve');
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp.seed_demo_operations() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp.seed_demo_operations()'::regprocedure);
  v_old text := $p$      perform erp.transition_document(v_so, 'submit');
      perform erp.transition_document(v_so, 'approve');
$p$;
  v_new text := $q$      perform erp.transition_document(v_so, 'submit');
      perform erp.approve_my_document_tasks(v_so, 'demonstration');
      perform erp.transition_document(v_so, 'approve');
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp.seed_demo_operations() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The suites approve the way a person must
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.approve_document(p_document_id uuid, p_reason text default null)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_claims  text := coalesce(current_setting('request.jwt.claims', true), '');
  v_me      uuid := erp.current_principal_id();
  v_task    uuid;
  v_auth    uuid;
  v_guard   integer := 0;
  q         erp.approval_request%rowtype;
  v_to      text;
begin
  -- Each pending task, decided by the person it is assigned to.
  loop
    select t.id, u.auth_user_id into v_task, v_auth
      from erp.approval_task t
      join erp.approval_request ar on ar.tenant_id = t.tenant_id and ar.id = t.approval_request_id
      left join erp.app_user u on u.tenant_id = t.tenant_id and u.id = t.assignee_user_id
     where t.tenant_id = v_tenant
       and ar.object_type = 'document'
       and ar.object_id = p_document_id
       and ar.status = 'pending'
       and t.status = 'pending'
     order by t.seq, t.created_at, t.id
     limit 1;

    exit when v_task is null;

    v_guard := v_guard + 1;
    if v_guard > 50 or v_auth is null then
      raise exception 'CLOVEERP_SUITE_APPROVAL_UNDECIDABLE: task % on document % is assigned to nobody who can sign in', v_task, p_document_id;
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    perform erp.decide_approval_task(v_task, true, coalesce(p_reason, 'suite'));
    perform set_config('request.jwt.claims', v_claims, true);
  end loop;

  -- Approved by the caller, unless the caller asked and somebody else was asked
  -- to give it in a live organisation: then by the last person who did.
  v_auth := null;
  select ar.* into q
    from erp.approval_request ar
   where ar.tenant_id = v_tenant
     and ar.object_type = 'document'
     and ar.object_id = p_document_id
     and ar.status in ('pending', 'approved', 'rejected')
   order by (ar.status = 'pending') desc, ar.requested_at desc, (ar.status = 'approved') desc
   limit 1;

  if found and q.requested_by = v_me and erp.tenant_is_live(v_tenant) then
    select u.auth_user_id into v_auth
      from erp.approval_task t
      join erp.app_user u on u.tenant_id = t.tenant_id and u.id = t.decided_by
     where t.tenant_id = v_tenant and t.approval_request_id = q.id
       and t.status = 'approved' and t.decided_by <> v_me
     order by t.decided_at desc, t.id
     limit 1;
  end if;

  if v_auth is null then
    v_to := erp.transition_document(p_document_id, 'approve', p_reason);
  else
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    v_to := erp.transition_document(p_document_id, 'approve', p_reason);
    perform set_config('request.jwt.claims', v_claims, true);
  end if;

  return v_to;
end;
$$;

comment on function erp_test.approve_document(uuid, text) is
  'Suite fixture. Decides every pending task on a document''s approval as the '
  'person it is assigned to, then approves the document: as the caller, or, '
  'where the caller asked in a live organisation, as the last person who '
  'approved a task. Restores the caller''s claims.';

revoke all on function erp_test.approve_document(uuid, text) from public, anon, authenticated;

-- The suites that approved a document straight after submitting it, decided a
-- task as the person who asked, or received against an order never sent.

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.procurement_suite()'::regprocedure);
  v_old text := $p$  perform erp.transition_document(v_po, 'submit');
  -- The caller's own task, not whichever came first: a step with two eligible
  -- approvers raises a task each, and deciding somebody else's is refused.
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_po and tk.status = 'pending'
              and tk.assignee_user_id = erp.current_principal_id() limit 1
  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;
$p$;
  v_new text := $q$  perform erp.transition_document(v_po, 'submit');
  -- The second administrator's own task: whoever asks is not asked to approve
  -- (20260914062000), so the step went to the other administrator alone.
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_po and tk.status = 'pending'
              and tk.assignee_user_id = erp.current_principal_id() limit 1
  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.procurement_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.procurement_suite()'::regprocedure);
  v_old text := $p$  perform erp.transition_document(v_lo, 'submit');
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_lo and tk.status = 'pending'
              and tk.assignee_user_id = erp.current_principal_id() limit 1
  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;
$p$;
  v_new text := $q$  perform erp.transition_document(v_lo, 'submit');
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_lo and tk.status = 'pending'
              and tk.assignee_user_id = erp.current_principal_id() limit 1
  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.procurement_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.procurement_suite()'::regprocedure);
  v_old text := $p$  -- Committed documents.
  perform erp.transition_document(v_po, 'approve');
$p$;
  v_new text := $q$  -- Committed documents. The large order's finance step is still open, and an
  -- approval holds the document (20260914062000): it is decided, and the order
  -- approved by the second administrator, because the first asked.
  perform erp_test.approve_document(v_po, 'suite');
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.procurement_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.sales_suite()'::regprocedure);
  v_old text := $p$  perform erp.transition_document(v_so,'submit');
  for t in select tk.id from erp.approval_task tk
$p$;
  v_new text := $q$  perform erp.transition_document(v_so,'submit');
  -- Decided by the second administrator: whoever asks is not asked to approve
  -- (20260914062000).
  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  for t in select tk.id from erp.approval_task tk
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.sales_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.sales_suite()'::regprocedure);
  v_old text := $p$  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;

  -- 25,000 against a limit of 1,000,000, so credit is skipped$p$;
  v_new text := $q$  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);

  -- 25,000 against a limit of 1,000,000, so credit is skipped$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.sales_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.finance_depth_suite()'::regprocedure);
  v_old text := $p$  perform erp.transition_document(v_grn,'submit');
  perform erp.transition_document(v_grn,'approve');
$p$;
  v_new text := $q$  perform erp.transition_document(v_grn,'submit');
  perform erp_test.approve_document(v_grn, 'suite');
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.finance_depth_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.finance_depth_suite()'::regprocedure);
  v_old text := $p$    perform erp.transition_document(v_po2,'submit');
    perform erp.transition_document(v_po2,'approve');
$p$;
  v_new text := $q$    perform erp.transition_document(v_po2,'submit');
    perform erp_test.approve_document(v_po2, 'suite');
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.finance_depth_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.finance_suite()'::regprocedure);
  v_old text := $p$  perform erp.transition_document(v_so,'submit');
  perform erp.transition_document(v_so,'approve');
$p$;
  v_new text := $q$  perform erp.transition_document(v_so,'submit');
  perform erp_test.approve_document(v_so, 'suite');
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.finance_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.sales_depth_suite()'::regprocedure);
  v_old text := $p$  perform erp.transition_document(v_so,'submit');
  perform erp.transition_document(v_so,'approve');
$p$;
  v_new text := $q$  perform erp.transition_document(v_so,'submit');
  perform erp_test.approve_document(v_so, 'suite');
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.sales_depth_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.procurement_controls_suite()'::regprocedure);
  v_old text := $p$  perform erp.transition_document(v_po,'submit');
  perform erp.transition_document(v_po,'approve');
$p$;
  v_new text := $q$  perform erp.transition_document(v_po,'submit');
  perform erp_test.approve_document(v_po, 'suite');
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.procurement_controls_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.configuration_wiring_suite()'::regprocedure);
  v_old text := $p$    perform erp.transition_document(v_so, 'submit');
    perform erp.transition_document(v_so, 'approve');
$p$;
  v_new text := $q$    perform erp.transition_document(v_so, 'submit');
    perform erp_test.approve_document(v_so, 'wiring suite');
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.configuration_wiring_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.demo_history_suite()'::regprocedure);
  v_old text := $p$  perform erp.transition_document(v_po, 'submit'); perform erp.transition_document(v_po, 'approve');
$p$;
  v_new text := $q$  perform erp.transition_document(v_po, 'submit'); perform erp_test.approve_document(v_po, 'suite');
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.demo_history_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.second_organisation_suite()'::regprocedure);
  v_old text := $p$  perform public.erp_transition_document(v_po, 'submit', 'harness');
  perform public.erp_transition_document(v_po, 'approve', 'harness');
$p$;
  v_new text := $q$  perform public.erp_transition_document(v_po, 'submit', 'harness');
  perform erp_test.approve_document(v_po, 'harness');
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.second_organisation_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.supplier_bill_suite()'::regprocedure);
  v_old text := $p$    perform erp.transition_document(v_po, 'submit', null);
    perform erp.transition_document(v_po, 'approve', null);
$p$;
  v_new text := $q$    perform erp.transition_document(v_po, 'submit', null);
    perform erp_test.approve_document(v_po, null);
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.supplier_bill_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.supplier_bill_suite()'::regprocedure);
  v_old text := $p$    -- 4. An unposted receipt is not billed. Raised after the accrual is
    -- measured, because receiving against an order line moves the outstanding
    -- quantity whether or not the receipt has posted.
    v_grn2 := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_grn2, v_pol, 1, null);
$p$;
  v_new text := $q$    -- 4. An unposted receipt is not billed. Its line is written directly: the
    -- order it would be received against is received in full by now, and an
    -- order received in full takes no more (20260914062000).
    v_grn2 := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_grn2, v_item, 1, 1000, 'arrived, not yet posted');
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.supplier_bill_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.grant_suite()'::regprocedure);
  v_old text := $p$    v_supplier uuid; v_site uuid; v_item uuid; v_po uuid; v_grn uuid; v_line uuid;
$p$;
  v_new text := $q$    v_supplier uuid; v_site uuid; v_item uuid; v_po uuid; v_grn uuid; v_line uuid;
    v_task uuid;
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.grant_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.grant_suite()'::regprocedure);
  v_old text := $p$      perform public.erp_transition_document(v_po, 'submit', 'grant suite');
      perform public.erp_transition_document(v_po, 'approve', 'grant suite');
$p$;
  v_new text := $q$      perform public.erp_transition_document(v_po, 'submit', 'grant suite');
      -- The order waits on its approval (20260914062000). An organisation not
      -- yet live has one approver, who asked, and decides the task through the
      -- door that lists it and the door that decides it.
      for v_task in
        select (e ->> 'task_id')::uuid
          from jsonb_array_elements(public.erp_my_approvals()) e
         where (e ->> 'object_id')::uuid = v_po
      loop
        perform public.erp_decide_approval(v_task, true, 'grant suite');
      end loop;
      perform public.erp_transition_document(v_po, 'approve', 'grant suite');
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.grant_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.commercial_quote_suite()'::regprocedure);
  v_old text := $p$  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  v_state := erp.approve_quote(v_q2);
$p$;
  v_new text := $q$  -- The author asked for the approval, so the approver moves the quote on
  -- (20260914062000).
  v_state := erp.approve_quote(v_q2);
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.commercial_quote_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.order_behaviour_suite()'::regprocedure);
  v_old text := $p$    perform erp.set_order_behaviour(v_cons, 'consignment');
    v_grn := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
$p$;
  v_new text := $q$    perform erp.set_order_behaviour(v_cons, 'consignment');
    -- Sent before anything is received against it (20260914062000).
    perform erp.transition_document(v_cons, 'submit');
    perform erp_test.approve_document(v_cons, 'suite');
    perform erp.transition_document(v_cons, 'send');
    v_grn := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.order_behaviour_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.actionable_documents_suite()'::regprocedure);
  v_old text := $p$            and v_largs = 'p_document_id uuid, p_type_code text, p_limit integer, p_open_only boolean';$p$;
  v_new text := $q$            and v_largs = 'p_document_id uuid, p_type_code text, p_limit integer, p_open_only boolean, p_document_states text[]';$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.actionable_documents_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The refusals, and the words on the screens
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_DOCUMENT_APPROVAL_PENDING',
  'Approving a document whose approval has not been given yet.',
  'Submitting it asked the approving role to agree. Until the people asked have decided, approving the document would be approving it without them.',
  'Wait for the tasks under My approvals to be decided, then approve the document.');

select erp.register_refusal('CLOVEERP_DOCUMENT_APPROVAL_REJECTED',
  'Approving a document whose approval was refused.',
  'Somebody asked to approve it said no, and a single refusal decides an approval.',
  'Send the document back to draft, change what was refused, and submit it again.');

select erp.register_refusal('CLOVEERP_DOCUMENT_SELF_APPROVAL',
  'Approving a document you submitted for approval yourself.',
  'An approval is a second person agreeing. Once the organisation is live, whoever asks for one does not give it.',
  'Ask another holder of the approving role to decide it. If nobody else holds that role, give it to a second person.');

select erp.register_refusal('CLOVEERP_APPROVAL_NO_OTHER_APPROVER',
  'Submitting a document for approval when you are the only person who could approve it.',
  'Whoever submits a document is not asked to approve it, and nobody else holds the approving role, so nobody could agree.',
  'Give the approving role to a second person, or choose another approver role for these documents on the Configuration screen, then submit again.');

select erp.register_refusal('CLOVEERP_ORDER_NOT_SENT',
  'Receiving goods against a purchase order that has not been sent to the supplier, or has already been received in full.',
  'An order commits the organisation when the supplier is sent it. A draft, an order waiting on its approval, or one approved and never sent has promised nothing, so there is nothing to receive against.',
  'Have the order approved and send it to the supplier, then receive against it. Goods beyond an order received in full need an order of their own.');

select erp.register_refusal('CLOVEERP_APPROVER_ROLE_UNKNOWN',
  'Naming an approver role this organisation does not have.',
  'Approvals are asked of the people holding a role, and a role that does not exist has nobody in it.',
  'Choose one of the organisation''s roles, or leave the approver role empty to use the default.');

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). Added when an approval began holding its document and the Configuration screen began naming who approves.'
  from (values
    ('Approver role'),
    ('Records the approval chain the value and the department resolve to. It asks nobody to approve.')
) as v(text)
on conflict (key, locale) do nothing;


-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A live organisation with two administrators, procurement and sales installed
-- through the Configuration screen's doors naming the standard purchasing and
-- sales roles as approvers, purchasing held by both and sales by the first
-- alone. Then an organisation not yet live, with one person. Each is built
-- inside a block that ends by raising, so nothing outlives the suite; the
-- cases are answered from what the blocks recorded.

create or replace function erp_test.approval_hold_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();   -- the first administrator, who buys and sells
  a2       uuid := gen_random_uuid();   -- the second, who approves
  a3       uuid := gen_random_uuid();   -- the one person in an organisation not yet live
  r        record;
  r3       record;
  res      jsonb;
  v_second uuid;
  v_tok    text;
  cs_fin   uuid;
  cs_proc  uuid;
  cs_sales uuid;
  v_state  text;
  v_state3 text;
  -- The doors as the catalogue holds them.
  v_pn     integer;
  v_pargs  text;
  v_pdef   boolean;
  v_pgrant boolean;
  v_sn     integer;
  v_sargs  text;
  v_sdef   boolean;
  v_sgrant boolean;
  v_ln     integer;
  v_largs  text;
  -- The live organisation.
  v_uom    uuid;
  v_site   uuid;
  v_sup    uuid;
  v_cust   uuid;
  v_item   uuid;
  v_po_roles text[];
  v_so_roles text[];
  v_def_held    text;
  v_def_absent  text;
  v_def_unheld  text;
  v_def_unknown text;
  v_po     uuid;
  v_pol    uuid;
  v_req    uuid;
  v_task   uuid;
  v_tasks  integer;
  v_task_to   uuid;
  v_task_role text;
  v_pending_err   text;
  v_selftask      uuid;
  v_selftask_err  text;
  v_decided       text;
  v_selftrans_err text;
  v_approved      text;
  v_po2    uuid;
  v_reject_err text;
  v_so     uuid;
  v_so_err   text;
  v_so_state text;
  v_rq     uuid;
  v_rq_state    text;
  v_rq_requests integer;
  v_po3    uuid;
  v_pol3   uuid;
  v_grn    uuid;
  v_draft_err    text;
  v_approved_err text;
  v_sent_err     text;
  v_sent_line    uuid;
  v_lines_before uuid[];
  v_lines_sent   uuid[];
  v_lines_old    uuid[];
  -- The organisation not yet live.
  v_uom3   uuid;
  v_site3  uuid;
  v_sup3   uuid;
  v_item3  uuid;
  v_po4    uuid;
  v_task4_to  uuid;
  v_approved4 text;
begin
  select count(*), min(pg_catalog.pg_get_function_identity_arguments(p.oid)),
         coalesce(bool_or(p.prosecdef), true),
         coalesce(bool_and(pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                           and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')), false)
    into v_pn, v_pargs, v_pdef, v_pgrant
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_configure_procurement';

  select count(*), min(pg_catalog.pg_get_function_identity_arguments(p.oid)),
         coalesce(bool_or(p.prosecdef), true),
         coalesce(bool_and(pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                           and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')), false)
    into v_sn, v_sargs, v_sdef, v_sgrant
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_configure_sales';

  select count(*), min(pg_catalog.pg_get_function_identity_arguments(p.oid))
    into v_ln, v_largs
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_document_lines';

  -- ───────────────────────────────────────────────────────────────────────────
  -- A live organisation
  -- ───────────────────────────────────────────────────────────────────────────
  begin
    select * into r from erp.provision_tenant(
      'zz-hold-' || v_hex, 'Approval hold suite',
      'admin@zz-hold-' || v_hex || '.test', 'Hold Admin');

    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zz-hold-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid;
    v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

    -- Installed through the doors the Configuration screen calls, each naming
    -- the role that approves. Live, so somebody else approves the changes.
    cs_fin := erp.configure_finance();
    cs_proc := (public.erp_configure_procurement(1000000, 'purchasing') ->> 'change_set_id')::uuid;
    cs_sales := (public.erp_configure_sales(15, 'sales') ->> 'change_set_id')::uuid;

    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(cs_fin);
    perform erp.promote_change_set(cs_fin);
    perform erp.approve_change_set(cs_proc);
    perform erp.promote_change_set(cs_proc);
    perform erp.approve_change_set(cs_sales);
    perform erp.promote_change_set(cs_sales);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    select array_agg(distinct ro.code order by ro.code) into v_po_roles
      from erp.approval_chain c
      join erp.approval_chain_version v
        on v.tenant_id = c.tenant_id and v.approval_chain_id = c.id and v.status = 'active'
      join erp.approval_step s on s.tenant_id = v.tenant_id and s.approval_chain_version_id = v.id
      join erp.role ro on ro.tenant_id = s.tenant_id and ro.id = s.role_id
     where c.tenant_id = r.tenant_id and c.code = 'purchase_order_value';
    select array_agg(distinct ro.code order by ro.code) into v_so_roles
      from erp.approval_chain c
      join erp.approval_chain_version v
        on v.tenant_id = c.tenant_id and v.approval_chain_id = c.id and v.status = 'active'
      join erp.approval_step s on s.tenant_id = v.tenant_id and s.approval_chain_version_id = v.id
      join erp.role ro on ro.tenant_id = s.tenant_id and ro.id = s.role_id
     where c.tenant_id = r.tenant_id and c.code = 'sales_order_terms';

    -- Purchasing is held by both administrators; sales by the first alone.
    perform erp.grant_role(r.admin_user_id, 'purchasing', null, null, 'buys, and could approve');
    perform erp.grant_role(v_second, 'purchasing', null, null, 'approves');
    perform erp.grant_role(r.admin_user_id, 'sales', null, null, 'sells, and alone could approve');

    v_def_held := erp.approver_role_for(null, 'purchasing');
    v_def_absent := erp.approver_role_for(null, 'zz_absent_' || v_hex);
    v_def_unheld := erp.approver_role_for(null, 'planning');
    begin
      perform erp.approver_role_for('zz_unknown_' || v_hex, 'purchasing');
    exception when others then
      v_def_unknown := left(sqlerrm, 200);
    end;

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

    -- An order below the threshold: one step, asked of purchasing.
    v_po := erp.open_document('purchase_order', v_sup, null, v_site);
    v_pol := erp.add_document_line(v_po, v_item, 10, 5000, 'Ten widgets');
    perform erp.transition_document(v_po, 'submit');
    select q.id into v_req
      from erp.approval_request q
     where q.tenant_id = r.tenant_id and q.object_type = 'document' and q.object_id = v_po
       and q.status = 'pending';
    select count(*), min(t.assignee_user_id::text)::uuid, min(ro.code)
      into v_tasks, v_task_to, v_task_role
      from erp.approval_task t
      left join erp.role ro on ro.tenant_id = t.tenant_id and ro.id = t.assignee_role_id
     where t.tenant_id = r.tenant_id and t.approval_request_id = v_req and t.status = 'pending';

    -- Pending: not approved, even by somebody who may approve.
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    begin
      perform erp.transition_document(v_po, 'approve');
    exception when others then
      v_pending_err := left(sqlerrm, 200);
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- A task naming the person who asked, as one raised before this rule.
    insert into erp.approval_task (
      tenant_id, approval_request_id, approval_step_id, step_code, seq,
      assignee_user_id, assignee_role_id, status)
    select t.tenant_id, t.approval_request_id, t.approval_step_id, t.step_code, t.seq,
           r.admin_user_id, t.assignee_role_id, 'pending'
      from erp.approval_task t
     where t.tenant_id = r.tenant_id and t.approval_request_id = v_req and t.status = 'pending'
     limit 1
    returning id into v_selftask;
    begin
      perform erp.decide_approval_task(v_selftask, true, 'my own order');
    exception when others then
      v_selftask_err := left(sqlerrm, 200);
    end;

    -- The second administrator decides; the first still may not approve.
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    select t.id into v_task
      from erp.approval_task t
     where t.tenant_id = r.tenant_id and t.approval_request_id = v_req
       and t.status = 'pending' and t.assignee_user_id = v_second
     limit 1;
    v_decided := erp.decide_approval_task(v_task, true, 'agreed')::text;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    begin
      perform erp.transition_document(v_po, 'approve');
    exception when others then
      v_selftrans_err := left(sqlerrm, 200);
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    v_approved := erp.transition_document(v_po, 'approve');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- A refused approval holds the document too.
    v_po2 := erp.open_document('purchase_order', v_sup, null, v_site);
    perform erp.add_document_line(v_po2, v_item, 1, 5000, 'One widget');
    perform erp.transition_document(v_po2, 'submit');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    select t.id into v_task
      from erp.approval_task t
      join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
     where q.tenant_id = r.tenant_id and q.object_type = 'document' and q.object_id = v_po2
       and t.status = 'pending' and t.assignee_user_id = v_second
     limit 1;
    perform erp.decide_approval_task(v_task, false, 'not this quarter');
    begin
      perform erp.transition_document(v_po2, 'approve');
    exception when others then
      v_reject_err := left(sqlerrm, 200);
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- Sales is approved by the sales role, which only the first holds.
    v_so := erp.open_document('sales_order', v_cust, null, v_site);
    perform erp.add_document_line(v_so, v_item, 1, 9900, 'One widget');
    begin
      perform erp.transition_document(v_so, 'submit');
    exception when others then
      v_so_err := left(sqlerrm, 200);
    end;
    select s.code into v_so_state
      from erp.object_state os
      join erp.state s on s.id = os.current_state_id
     where os.tenant_id = r.tenant_id and os.object_type = 'document' and os.object_id = v_so;

    -- A requisition's type names no chain: approved on the permission alone.
    v_rq := erp.open_document('requisition', v_sup);
    perform erp.add_document_line(v_rq, v_item, 1, 5000, 'One widget');
    perform erp.transition_document(v_rq, 'submit');
    v_rq_state := erp.transition_document(v_rq, 'approve');
    select count(*) into v_rq_requests
      from erp.approval_request q
     where q.tenant_id = r.tenant_id and q.object_id = v_rq;

    -- Receiving: a draft order, the approved one before it is sent, and after.
    v_po3 := erp.open_document('purchase_order', v_sup, null, v_site);
    v_pol3 := erp.add_document_line(v_po3, v_item, 10, 5000, 'Ten more widgets');
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    begin
      perform erp.receive_against(v_grn, v_pol3, 1);
    exception when others then
      v_draft_err := left(sqlerrm, 200);
    end;
    begin
      perform erp.receive_against(v_grn, v_pol, 1);
    exception when others then
      v_approved_err := left(sqlerrm, 200);
    end;
    v_lines_before := array(select (e ->> 'line_id')::uuid from jsonb_array_elements(
      public.erp_document_lines(p_type_code => 'purchase_order', p_limit => 1000, p_open_only => true,
                                p_document_states => array['sent', 'partially_received'])) e);
    perform erp.transition_document(v_po, 'send');
    begin
      v_sent_line := erp.receive_against(v_grn, v_pol, 10);
    exception when others then
      v_sent_err := left(sqlerrm, 200);
    end;
    v_lines_sent := array(select (e ->> 'line_id')::uuid from jsonb_array_elements(
      public.erp_document_lines(p_type_code => 'purchase_order', p_limit => 1000, p_open_only => true,
                                p_document_states => array['sent', 'partially_received'])) e);
    v_lines_old := array(select (e ->> 'line_id')::uuid from jsonb_array_elements(
      public.erp_document_lines(v_po, 'purchase_order', 200)) e);

    raise exception 'CLOVEERP_APPROVAL_HOLD_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_APPROVAL_HOLD_SUITE_UNDO' then
      v_state := left(sqlerrm, 300);
    end if;
  end;

  -- ───────────────────────────────────────────────────────────────────────────
  -- An organisation not yet live, with one person
  -- ───────────────────────────────────────────────────────────────────────────
  begin
    select * into r3 from erp.provision_tenant(
      'zz-hold3-' || v_hex, 'Approval hold suite, not yet live',
      'admin@zz-hold3-' || v_hex || '.test', 'Setup Admin');
    update erp.environment set is_live = false where tenant_id = r3.tenant_id and is_self;
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(r3.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(1000000);

    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r3.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom3;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r3.tenant_id, r3.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site3;
    insert into erp.party (tenant_id, code, name, status)
    values (r3.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup3;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r3.tenant_id, v_sup3, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r3.tenant_id, 'WID', 'Widget', v_uom3, 'active') returning id into v_item3;

    v_po4 := erp.open_document('purchase_order', v_sup3, null, v_site3);
    perform erp.add_document_line(v_po4, v_item3, 1, 5000, 'One widget');
    perform erp.transition_document(v_po4, 'submit');
    select t.assignee_user_id into v_task4_to
      from erp.approval_task t
      join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
     where q.tenant_id = r3.tenant_id and q.object_type = 'document' and q.object_id = v_po4
       and t.status = 'pending'
     limit 1;
    perform erp.approve_my_document_tasks(v_po4, 'setting up');
    v_approved4 := erp.transition_document(v_po4, 'approve');

    raise exception 'CLOVEERP_APPROVAL_HOLD_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_APPROVAL_HOLD_SUITE_UNDO' then
      v_state3 := left(sqlerrm, 300);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ───────────────────────────────────────────────────────────────────────────
  -- Who approves
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'the configuration doors are one function each, run as the caller, and take an approver role after the threshold';
  passed := coalesce(v_pn = 1 and v_sn = 1 and not v_pdef and not v_sdef and v_pgrant and v_sgrant
            and v_pargs = 'p_approval_threshold_minor bigint, p_approver_role text'
            and v_sargs = 'p_discount_threshold_pct numeric, p_approver_role text', false);
  detail := format('procurement: %s function(s) (%s), definer %s, granted %s; sales: %s function(s) (%s), definer %s, granted %s',
                   v_pn, coalesce(v_pargs, 'none'), v_pdef, v_pgrant, v_sn, coalesce(v_sargs, 'none'), v_sdef, v_sgrant);
  return next;

  case_name := 'installed naming an approver role, every step of the order''s chain asks that role';
  passed := coalesce(v_state is null and v_po_roles = array['purchasing'] and v_so_roles = array['sales'], false);
  detail := coalesce(v_state, format('purchase order steps ask %s; sales order steps ask %s', v_po_roles, v_so_roles));
  return next;

  case_name := 'with no role named, the preferred role is asked where somebody holds it, and administrator where nobody does or it does not exist';
  passed := coalesce(v_state is null and v_def_held = 'purchasing' and v_def_absent = 'administrator'
            and v_def_unheld = 'administrator', false);
  detail := coalesce(v_state, format('held %s; absent %s; nobody holds it %s', v_def_held, v_def_absent, v_def_unheld));
  return next;

  case_name := 'a role the organisation does not have is refused by name';
  passed := coalesce(v_state is null and v_def_unknown like 'CLOVEERP_APPROVER_ROLE_UNKNOWN%', false);
  detail := coalesce(v_state, v_def_unknown, 'the unknown role was accepted');
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- The hold
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'submitting asks the approving role''s other holder, and not the person who submitted';
  passed := coalesce(v_state is null and v_tasks = 1 and v_task_to = v_second and v_task_role = 'purchasing', false);
  detail := coalesce(v_state, format('%s pending task(s); to the second administrator %s; role %s',
                                     v_tasks, v_task_to = v_second, v_task_role));
  return next;

  case_name := 'while its approval is pending a document is not approved, even by somebody who may approve';
  passed := coalesce(v_state is null and v_pending_err like 'CLOVEERP_DOCUMENT_APPROVAL_PENDING%', false);
  detail := coalesce(v_state, v_pending_err, 'the pending order was approved');
  return next;

  case_name := 'the person who asked cannot approve the task, even one that names them';
  passed := coalesce(v_state is null and v_selftask is not null
            and v_selftask_err like 'CLOVEERP_DOCUMENT_SELF_APPROVAL%', false);
  detail := coalesce(v_state, v_selftask_err, 'the person who asked approved their own task');
  return next;

  case_name := 'once the approval is given, the person who asked still cannot approve the document';
  passed := coalesce(v_state is null and v_decided = 'approved'
            and v_selftrans_err like 'CLOVEERP_DOCUMENT_SELF_APPROVAL%', false);
  detail := coalesce(v_state, format('the task decided %s; %s', v_decided,
                                     coalesce(v_selftrans_err, 'the person who asked approved the order')));
  return next;

  case_name := 'somebody else approves it once the approval is given';
  passed := coalesce(v_state is null and v_approved = 'approved', false);
  detail := coalesce(v_state, format('the order moved to %s', v_approved));
  return next;

  case_name := 'a refused approval holds the document too';
  passed := coalesce(v_state is null and v_reject_err like 'CLOVEERP_DOCUMENT_APPROVAL_REJECTED%', false);
  detail := coalesce(v_state, v_reject_err, 'the refused order was approved');
  return next;

  case_name := 'where only the person submitting holds the approving role, a live organisation refuses the submission';
  passed := coalesce(v_state is null and v_so_err like 'CLOVEERP_APPROVAL_NO_OTHER_APPROVER%'
            and v_so_state = 'draft', false);
  detail := coalesce(v_state, format('%s; the order is %s', coalesce(v_so_err, 'the order was submitted'), v_so_state));
  return next;

  case_name := 'a document type with no approval chain is approved as before, by whoever may';
  passed := coalesce(v_state is null and v_rq_state = 'approved' and v_rq_requests = 0, false);
  detail := coalesce(v_state, format('the requisition moved to %s with %s approval request(s)', v_rq_state, v_rq_requests));
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Receiving
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'goods are not received against a draft order';
  passed := coalesce(v_state is null and v_draft_err like 'CLOVEERP_ORDER_NOT_SENT%', false);
  detail := coalesce(v_state, v_draft_err, 'the draft order was received against');
  return next;

  case_name := 'nor against an order approved and not yet sent; once it is sent, they are';
  passed := coalesce(v_state is null and v_approved_err like 'CLOVEERP_ORDER_NOT_SENT%'
            and v_sent_err is null and v_sent_line is not null, false);
  detail := coalesce(v_state, format('before sending: %s; after: %s',
                                     coalesce(v_approved_err, 'received'), coalesce(v_sent_err, 'received')));
  return next;

  case_name := 'the line door lists only lines on documents in the states asked for, and keeps its old call';
  passed := coalesce(v_state is null and v_ln = 1
            and v_largs = 'p_document_id uuid, p_type_code text, p_limit integer, p_open_only boolean, p_document_states text[]'
            and not (v_pol = any (v_lines_before)) and not (v_pol3 = any (v_lines_before))
            and v_pol = any (v_lines_sent) and not (v_pol3 = any (v_lines_sent))
            and v_pol = any (v_lines_old), false);
  detail := coalesce(v_state, format('%s function(s) (%s); approved order''s line before sending %s, after %s; draft order''s line %s; old call %s',
                                     v_ln, coalesce(v_largs, 'none'), v_pol = any (v_lines_before),
                                     v_pol = any (v_lines_sent), v_pol3 = any (v_lines_sent), v_pol = any (v_lines_old)));
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Before go-live
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'before go-live the one person setting up is asked, decides, and approves';
  passed := coalesce(v_state3 is null and v_task4_to = r3.admin_user_id and v_approved4 = 'approved', false);
  detail := coalesce(v_state3, format('the task went to the person who asked %s; the order moved to %s',
                                      v_task4_to = r3.admin_user_id, v_approved4));
  return next;
end;
$$;

comment on function erp_test.approval_hold_suite() is
  'A live organisation with two administrators, procurement and sales installed '
  'through the Configuration doors naming purchasing and sales as approvers: '
  'who is asked, the hold while pending and after a refusal, maker and checker '
  'by task and by transition, a submission nobody else could approve, a type '
  'with no chain, receiving against draft, approved and sent orders, and the '
  'line door''s states; then an organisation not yet live with one person. '
  'Rolls back everything it made.';

create or replace function erp_test.assert_approval_hold_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 16;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*),
         count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_failed, v_detail
    from erp_test.approval_hold_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_APPROVAL_HOLD_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_failed > 0 then
    raise exception E'CLOVEERP_APPROVAL_HOLD_SUITE_FAILED: %/% case(s) failed\n%', v_failed, v_total, v_detail;
  end if;
  return format('approval hold: %s/%s cases passed', v_total - v_failed, v_total);
end;
$$;

revoke all on function erp_test.approval_hold_suite() from public, anon, authenticated;
revoke all on function erp_test.assert_approval_hold_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_authorise_codes_exist();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internals();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_session_context_hygiene();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_isolation();

select erp_test.assert_approval_hold_suite();
select erp_test.assert_procurement_suite();
select erp_test.assert_sales_suite();
select erp_test.assert_supplier_bill_suite();
select erp_test.assert_order_behaviour_suite();
select erp_test.assert_actionable_documents_suite();
