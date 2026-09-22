set lock_timeout = '30s';

-- =============================================================================
-- 20260922320000  An approval is not carried on a line anybody can draw
-- -----------------------------------------------------------------------------
-- A review of PR3 after it was green found that W1 (20260922240000) was an
-- approval bypass, and every finding below was reproduced on a built database
-- before this was written. W1 answered a submit, before asking anybody, in two
-- ways, and both were wrong.
--
-- ── ARM TWO: THE PARENT'S APPROVAL, FOLLOWED THROUGH A RELATION ──────────────
--
-- W1 followed erp.document_relation from the submitted document to a "parent"
-- and, where the parent's approval still covered the child's party and total,
-- wrote the child an approved request with no task. Its migration called this
-- arm "wired and dormant in the configuration the packs ship". It was neither
-- dormant nor safe:
--
--   public.erp_link_documents(from, to, kind) lets any holder of
--   procurement.order write any relation between any two documents in the
--   organisation. It checks neither document's type, state nor party.
--
-- So a buyer could open a new purchase order for the same supplier and total as
-- any approved one, link it as 'converts', submit it, and have it approved with
-- nobody asked. Reproduced, each inside a transaction rolled back:
--
--   one decided approval carried onto three new orders, the unlinked control
--   still waiting on its task;
--   carried from a parent that had been CANCELLED;
--   carried onto an order whose own request had been REFUSED, the inherited row
--   newer than the refusal and therefore governing it;
--   and approved by the person who raised it — the inherited request has no
--   task, so the check that stops a requester deciding their own request never
--   runs;
--   and across currencies, because the fingerprint compares total_minor and
--   ¥1,000,000 and $10,000 are the same number of minor units.
--
-- ── ARM ONE: THE DOCUMENT'S OWN STANDING APPROVAL ────────────────────────────
--
-- W1's migration called this "the live arm — a purchase order amended and
-- resubmitted". In the lifecycle the packs ship there is exactly one way back to
-- draft from pending_approval, and it is 'reject'. So the only resubmission this
-- arm could ever answer is one that followed a refusal, and what it did there
-- was:
--
--   undo the refusal — approve the tasks, reject the document at the approve
--   step, resubmit unchanged, and the old approval answered with nobody asked;
--   or strand the document — approved, amended, the amendment refused, the
--   amendment taken out again: resubmission returned the old approval and
--   raised nothing, the refused request still governed, and the order could not
--   be approved at the figure that had been approved;
--   or hold it on a stale question — a pending request for figures the document
--   no longer carried, because the short-circuit skipped the supersession
--   erp.request_approval() performs.
--
-- It also could not see what was bought: the context it fingerprints carries no
-- lines, so swapping ten widgets for a gold bar at the same total kept the
-- approval.
--
-- ── SO BOTH ARMS COME OUT ────────────────────────────────────────────────────
--
-- erp.request_document_approval_or_inherit() asks, every time, exactly as
-- erp.request_approval() did before PR3. It stays as the one place both doors
-- ask — the submit arm of erp.transition_document() and the require_approval
-- effect — so that the inheritance the doctrine does want has one place to go.
--
-- That inheritance is real and it is PR4's: "a purchase order created from an
-- approved requisition is born approved" (P1). It is safe there because the
-- purchase order is created BY the conversion, through a door that knows both
-- documents, rather than inferred afterwards from a relation any buyer can
-- draw. Trusting erp.document_relation as proof of lineage was the mistake, and
-- this migration does not try to make it safe after the fact.
--
-- erp.check_reapproval_required() is therefore called by nothing again. That is
-- the honest state until PR4 gives it a caller that can be trusted.
--
-- ── AND THE SUITE PINS THE REFUSALS, NOT THE SHORTCUT ────────────────────────
--
-- erp_test.inherited_approval_suite() asserted the shortcut — its case 5 linked
-- one purchase order to another and asserted the approval was carried, which is
-- the bypass written as a test. It is rewritten from the reproductions: a linked
-- order asks for its own approval; a refused order resubmitted asks again; an
-- approver's reject is not undone by resubmitting unchanged.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The routine asks, every time
-- ═════════════════════════════════════════════════════════════════════════════

do $was$
declare
  v_def text := pg_get_functiondef(
    'erp.request_document_approval_or_inherit(uuid, jsonb, uuid, uuid)'::regprocedure);
begin
  if position('check_reapproval_required' in v_def) = 0 then
    raise exception 'CLOVEERP_ROUTINE_UNRECOGNISED: erp.request_document_approval_or_inherit() no longer carries the two arms this migration removes'
      using hint = 'Read the deployed body and write the change against it under a new version.';
  end if;
end
$was$;

create or replace function erp.request_document_approval_or_inherit(
  p_document_id uuid,
  p_context     jsonb default '{}'::jsonb,
  p_entity_id   uuid default null,
  p_site_id     uuid default null)
returns uuid
language plpgsql
set search_path = ''
as $$
begin
  -- Asked every time (20260922320000). W1 answered a submit from the
  -- document's own standing approval or from a parent's, followed through
  -- erp.document_relation — which any buyer can write between any two
  -- documents, so one decision approved any number of orders, including
  -- refused ones and the requester's own. Inheritance belongs where the child
  -- is created by the conversion that knows its parent (PR4, P1), not here.
  return erp.request_approval('document', p_document_id, p_context, 1,
                              p_entity_id, p_site_id);
end;
$$;

comment on function erp.request_document_approval_or_inherit(uuid, jsonb, uuid, uuid) is
  'The one place a document asks for approval: the submit arm of '
  'erp.transition_document() and the require_approval effect both call it. It '
  'asks every time. An approval inherited from a parent is PR4''s, created by '
  'the conversion that makes the child, and never inferred from a relation.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The suite, rewritten from the reproductions
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.inherited_approval_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path = ''
as $suite$
declare
  v_hex     text := replace(gen_random_uuid()::text, '-', '');
  a1        uuid := gen_random_uuid();
  r         record;
  v_cs      uuid;
  v_uom     uuid; v_site uuid; v_sup uuid; v_item uuid;
  v_parent  uuid; v_linked uuid; v_refused uuid; v_undone uuid;
  v_req     uuid; v_status text; v_note text;
  v_n       integer; v_tasks integer; v_before integer; v_decided integer;
  v_refused_req uuid; v_refused_status text; v_new_req uuid; v_new_status text;
  v_line    uuid;
  v_msg     text;
  v_cases   integer := 0;
  v_def     text; v_td text; v_ee text;
  v_fixture text;
  v_claims  text;
  v_task    uuid; v_auth uuid;
begin
  begin
  select * into r from erp.provision_tenant(
    'zz-inh-' || v_hex, 'Inherited approval suite',
    'admin@zz-inh-' || v_hex || '.test', 'Inherited Approval Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);

  v_cs := erp.configure_finance();
  perform erp_test.promote_if_pending(v_cs);
  v_cs := erp.configure_inventory('average');
  perform erp_test.promote_if_pending(v_cs);
  v_cs := erp.configure_procurement(100000000);
  perform erp_test.promote_if_pending(v_cs);

  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
  values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
  perform erp.create_location(v_site, 'RECV', 'Goods in', 'receiving');
  insert into erp.party (tenant_id, code, name, status)
  values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (r.tenant_id, v_sup, 'supplier', 'active');
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (r.tenant_id, 'INH', 'Widget', v_uom, 'active') returning id into v_item;

  -- ── 1. Submitted, and asked for ───────────────────────────────────────────
  v_parent := erp.open_document('purchase_order', v_sup, r.entity_id, v_site);
  perform erp.add_document_line(v_parent, v_item, 10, 1000, 'ten widgets');
  perform erp.transition_document(v_parent, 'submit', 'inherited approval suite');
  select ar.id, ar.status::text into v_req, v_status
    from erp.approval_request ar
   where ar.tenant_id = r.tenant_id and ar.object_type = 'document' and ar.object_id = v_parent
   order by ar.requested_at desc, ar.id desc limit 1;
  select count(*) into v_tasks from erp.approval_task t
   where t.tenant_id = r.tenant_id and t.approval_request_id = v_req;

  v_cases := v_cases + 1;
  case_name := 'a purchase order submitted asks for approval, and somebody is asked';
  passed := v_status = 'pending' and v_tasks > 0;
  detail := format('the request is %s with %s task(s)', v_status, v_tasks);
  return next;

  -- ── 2. Decided ────────────────────────────────────────────────────────────
  -- erp_test.approve_document decides the tasks and takes the approve step.
  perform erp_test.approve_document(v_parent, 'inherited approval suite');
  select ar.status::text into v_status from erp.approval_request ar where ar.id = v_req;

  v_cases := v_cases + 1;
  case_name := 'and once it is decided the order is approved';
  passed := v_status = 'approved';
  detail := format('the request is %s', v_status);
  return next;

  -- ── 3. The bypass, closed ─────────────────────────────────────────────────
  -- The reproduction that sank W1: a new order for the same supplier and total,
  -- linked to the approved one through the door any buyer may use. Before
  -- 20260922320000 it was approved with no task and nobody asked.
  v_linked := erp.open_document('purchase_order', v_sup, r.entity_id, v_site);
  perform erp.add_document_line(v_linked, v_item, 10, 1000, 'the same ten');
  perform erp.link_documents(v_linked, v_parent, 'converts', null);
  perform erp.transition_document(v_linked, 'submit', 'inherited approval suite');
  select ar.id, ar.status::text, ar.decision_note into v_req, v_status, v_note
    from erp.approval_request ar
   where ar.tenant_id = r.tenant_id and ar.object_type = 'document' and ar.object_id = v_linked
   order by ar.requested_at desc, ar.id desc limit 1;
  select count(*) into v_tasks from erp.approval_task t
   where t.tenant_id = r.tenant_id and t.approval_request_id = v_req;
  v_msg := null;
  begin
    perform erp.transition_document(v_linked, 'approve', 'inherited approval suite');
  exception when others then
    v_msg := sqlerrm;
  end;

  -- Approving it either waits on that task or, for an administrator in an
  -- organisation that allows it, decides the task in the same press — which is
  -- the product's existing one-press administrator approval, and a recorded
  -- decision. What must never happen again is an approval with no task decided.
  select count(*) into v_decided from erp.approval_task t
   where t.tenant_id = r.tenant_id and t.approval_request_id = v_req
     and t.status = 'approved' and t.decided_by is not null;

  v_cases := v_cases + 1;
  case_name := 'an order linked to an approved one asks for its own approval, and is approved only by a decision on it';
  passed := v_status = 'pending' and v_tasks > 0
        and coalesce(v_note, '') not like 'carried from%'
        and (v_msg like 'CLOVEERP_DOCUMENT_APPROVAL_PENDING%' or (v_msg is null and v_decided > 0));
  detail := format('its own request was %s with %s task(s) and nothing carried; approving it %s',
                   v_status, v_tasks,
                   case when v_msg is null then format('went through on %s decided task(s) of its own', v_decided)
                        else 'waited: ' || left(v_msg, 60) end);
  return next;

  -- ── 4. A refused amendment, taken back out, is asked about again ─────────
  -- The route that stranded an order under W1: approved at ten, sent back to
  -- draft and raised to fifty, the fifty refused, sent back and reduced to ten
  -- again. W1 answered the last submit with the approval given at ten and
  -- raised nothing, while the refusal of the fifty — newer — still governed,
  -- so the order could never be approved at the figure that HAD been approved.
  --
  -- The requests are aged apart because in one transaction they all carry
  -- now(), and erp.require_document_approval() breaks that tie in favour of an
  -- approved request, which would hide exactly this.
  v_refused := erp.open_document('purchase_order', v_sup, r.entity_id, v_site);
  v_line := erp.add_document_line(v_refused, v_item, 10, 1000, 'ten widgets');
  v_claims := coalesce(current_setting('request.jwt.claims', true), '');
  perform erp.transition_document(v_refused, 'submit', 'inherited approval suite: at ten');
  loop  -- the ten, approved
    select t.id, u.auth_user_id into v_task, v_auth
      from erp.approval_task t
      join erp.approval_request ar on ar.tenant_id = t.tenant_id and ar.id = t.approval_request_id
      left join erp.app_user u on u.tenant_id = t.tenant_id and u.id = t.assignee_user_id
     where t.tenant_id = r.tenant_id and ar.object_type = 'document' and ar.object_id = v_refused
       and ar.status = 'pending' and t.status = 'pending'
     order by t.seq, t.created_at, t.id limit 1;
    exit when v_task is null;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    perform erp.decide_approval_task(v_task, true, 'inherited approval suite: ten approved');
    perform set_config('request.jwt.claims', v_claims, true);
  end loop;
  perform erp.transition_document(v_refused, 'reject', 'back to draft to amend');
  update erp.approval_request
     set requested_at = requested_at - interval '2 days', decided_at = decided_at - interval '2 days'
   where tenant_id = r.tenant_id and object_type = 'document' and object_id = v_refused;

  perform erp.amend_document_line(v_line, 50, 'fifty now');
  perform erp.transition_document(v_refused, 'submit', 'inherited approval suite: at fifty');
  loop  -- the fifty, refused
    select t.id, u.auth_user_id into v_task, v_auth
      from erp.approval_task t
      join erp.approval_request ar on ar.tenant_id = t.tenant_id and ar.id = t.approval_request_id
      left join erp.app_user u on u.tenant_id = t.tenant_id and u.id = t.assignee_user_id
     where t.tenant_id = r.tenant_id and ar.object_type = 'document' and ar.object_id = v_refused
       and ar.status = 'pending' and t.status = 'pending'
     order by t.seq, t.created_at, t.id limit 1;
    exit when v_task is null;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    perform erp.decide_approval_task(v_task, false, 'inherited approval suite: fifty refused');
    perform set_config('request.jwt.claims', v_claims, true);
  end loop;
  perform erp.transition_document(v_refused, 'reject', 'the fifty was refused');
  update erp.approval_request
     set requested_at = requested_at - interval '1 day', decided_at = decided_at - interval '1 day'
   where tenant_id = r.tenant_id and object_type = 'document' and object_id = v_refused
     and requested_at > now() - interval '1 day';

  perform erp.amend_document_line(v_line, 10, 'back to ten, which was approved');
  select count(*) into v_before from erp.approval_request ar
   where ar.tenant_id = r.tenant_id and ar.object_type = 'document' and ar.object_id = v_refused;
  perform erp.transition_document(v_refused, 'submit', 'inherited approval suite: at ten again');
  select count(*) into v_n from erp.approval_request ar
   where ar.tenant_id = r.tenant_id and ar.object_type = 'document' and ar.object_id = v_refused;
  select ar.id, ar.status::text into v_new_req, v_new_status
    from erp.approval_request ar
   where ar.tenant_id = r.tenant_id and ar.object_type = 'document' and ar.object_id = v_refused
   order by (ar.status = 'pending') desc, ar.requested_at desc, (ar.status = 'approved') desc
   limit 1;
  select ar.status::text into v_refused_status from erp.approval_request ar
   where ar.tenant_id = r.tenant_id and ar.object_type = 'document' and ar.object_id = v_refused
     and ar.status = 'rejected' limit 1;
  v_msg := null;
  begin
    perform erp.transition_document(v_refused, 'approve', 'inherited approval suite');
  exception when others then
    v_msg := sqlerrm;
  end;

  v_cases := v_cases + 1;
  case_name := 'a refused amendment taken back out is asked about again, and is not stranded by the refusal';
  passed := v_n = v_before + 1
        and v_new_status = 'pending'
        and v_refused_status = 'rejected'
        and coalesce(v_msg, '') not like 'CLOVEERP_DOCUMENT_APPROVAL_REJECTED%';
  detail := format('%s request(s) before the last submit, %s after; the governing one is %s; approving it %s',
                   v_before, v_n, coalesce(v_new_status, 'missing'),
                   case when v_msg is null then 'went through on a fresh decision'
                        else 'said: ' || left(v_msg, 60) end);
  return next;

  -- ── 5. An approver's reject is not undone by resubmitting ────────────────
  -- The tasks approved, then the order rejected at the approve step and
  -- resubmitted unchanged. Before 20260922320000 the old approval answered
  -- and the next approve passed on permission alone.
  v_undone := erp.open_document('purchase_order', v_sup, r.entity_id, v_site);
  perform erp.add_document_line(v_undone, v_item, 10, 1000, 'ten widgets, rejected at the step');
  perform erp.transition_document(v_undone, 'submit', 'inherited approval suite');
  -- The tasks decided in favour, and the order left at the approve step, so an
  -- approver can still reject it there — erp_test.approve_document would take
  -- the step as well.
  loop
    select t.id, u.auth_user_id into v_task, v_auth
      from erp.approval_task t
      join erp.approval_request ar on ar.tenant_id = t.tenant_id and ar.id = t.approval_request_id
      left join erp.app_user u on u.tenant_id = t.tenant_id and u.id = t.assignee_user_id
     where t.tenant_id = r.tenant_id and ar.object_type = 'document' and ar.object_id = v_undone
       and ar.status = 'pending' and t.status = 'pending'
     order by t.seq, t.created_at, t.id limit 1;
    exit when v_task is null;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    perform erp.decide_approval_task(v_task, true, 'inherited approval suite: approved');
    perform set_config('request.jwt.claims', v_claims, true);
  end loop;
  perform erp.transition_document(v_undone, 'reject', 'refused at the approve step');
  perform erp.transition_document(v_undone, 'submit', 'resubmitted unchanged');
  select ar.id, ar.status::text into v_req, v_status
    from erp.approval_request ar
   where ar.tenant_id = r.tenant_id and ar.object_type = 'document' and ar.object_id = v_undone
   order by (ar.status = 'pending') desc, ar.requested_at desc, ar.id desc limit 1;
  select count(*) into v_tasks from erp.approval_task t
   where t.tenant_id = r.tenant_id and t.approval_request_id = v_req and t.status = 'pending';

  v_cases := v_cases + 1;
  case_name := 'an approver''s reject is not undone by resubmitting the same order unchanged';
  passed := v_status = 'pending' and v_tasks > 0;
  detail := format('the governing request is %s with %s task(s) waiting', v_status, v_tasks);
  return next;

  -- ── 6. The routine, and the doors that use it ────────────────────────────
  v_def := pg_get_functiondef(
    'erp.request_document_approval_or_inherit(uuid, jsonb, uuid, uuid)'::regprocedure);
  v_td := pg_get_functiondef('erp.transition_document(uuid, text, text)'::regprocedure);
  v_ee := pg_get_functiondef(
    'erp.execute_effects(text, uuid, jsonb, jsonb, uuid, uuid, text, text, text)'::regprocedure);

  v_cases := v_cases + 1;
  case_name := 'both places that ask for a document approval ask through one routine, and it reads no lineage';
  passed := position('request_document_approval_or_inherit' in v_td) > 0
        and position('request_document_approval_or_inherit' in v_ee) > 0
        and position('erp.request_approval(' in erp.prosrc_code(v_def)) > 0
        and position('document_relation' in erp.prosrc_code(v_def)) = 0
        and position('check_reapproval_required' in erp.prosrc_code(v_def)) = 0;
  detail := 'the submit arm and the require_approval effect; the routine asks erp.request_approval and follows no relation';
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_fixture := left(sqlerrm, 300);
    end if;
  end;

  -- ── 7. Undone ─────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := not exists (select 1 from erp.tenant where code = 'zz-inh-' || v_hex)
        and v_fixture is null;
  detail := coalesce('the fixture stopped early: ' || v_fixture,
                     'the organisation rolled back with its orders and its approvals');
  return next;

  if v_cases <> 7 then
    raise exception 'CLOVEERP_SUITE_SHRANK: inherited_approval_suite ran % cases, expected 7 — %',
      v_cases, coalesce(v_fixture, 'no case was skipped');
  end if;
end;
$suite$;

comment on function erp_test.inherited_approval_suite() is
  'A document asks for its own approval: not carried from an order it was '
  'linked to, not answered by a standing approval after a refusal, and not '
  'undone by resubmitting unchanged. The reproductions that sank W1, as cases.';

create or replace function erp_test.assert_inherited_approval_suite()
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
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ')
           filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.inherited_approval_suite() s;

  if v_total <> 7 then
    raise exception 'CLOVEERP_INHERITED_APPROVAL_SUITE_SHRANK: % case(s), expected 7', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;

  if v_failed > 0 then
    raise exception 'CLOVEERP_INHERITED_APPROVAL_SUITE_FAILED: %/% case(s) failed%',
      v_failed, v_total, E'\n  ' || v_detail
      using hint = 'An approval given without anybody deciding it is the defect this suite exists for. Read the case that failed.';
  end if;
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
