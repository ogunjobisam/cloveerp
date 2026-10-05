set lock_timeout = '30s';

-- =============================================================================
-- 20261007010000  Approval history reads the requests
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-29). Governance's
-- Approval history said it held "every approval that has been raised, and each
-- step of it", and read public.erp_approval_audit, which read only
-- erp.approval_routing_stamp. A stamp is written by two presses alone, "Work
-- out who approves" (erp_stamp_document_approval) and "Route an approval by
-- value" (erp_stamp_approval_routing). Submitting a document asks for its
-- approval through erp.request_approval, which writes erp.approval_request and
-- erp.approval_task and never a stamp. On live the demonstration held 6 stamps
-- and 602 approval requests, so the history showed about 1% of its approvals,
-- while Decisions beneath it, which reads the tasks, listed them.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_approval_audit, same signature, permission and grants: one
--      row per step each approval request reached, read from the request and
--      its tasks. A row says what it was for (the document, its number and
--      type), its value and who asked, the step, who it went to (the person,
--      or the role where a task names no person) and who was covered for: the
--      person a delegation acted for, or whose task was escalated. A step the
--      request skipped because its condition did not apply went to nobody and
--      is not listed, as Decisions does not list it. The routing stamp is no
--      longer read here: it records what the routing rules would answer, not
--      an approval, and stays on the document's Approval routing card and on
--      Organisation and approval routing (erp_approval_routing_stamps).
--   B. erp_test.approval_history_suite: a submitted requisition is in the
--      history although nothing was stamped; a delegated step names who it
--      went to and who was covered for; a stamp alone adds no row; the filter
--      and the limit hold; another organisation's approvals are not read; and
--      somebody without administration.audit_read is refused.
--
-- The screen's half (the row key, "Requested" for the date, the step by name,
-- and the two columns only a stamp could fill, "Chosen by" and "Rule
-- version", dropped) is in src/routes/governance/index.tsx.
--
-- On production: one door is replaced. No table is altered and no row is
-- changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The door
-- ─────────────────────────────────────────────────────────────────────────────

do $guard$
declare
  v_sig constant text := 'public.erp_approval_audit(text,integer)';
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
begin
  if strpos(v_src, '20261007010000') > 0 then
    raise notice '% already reads the requests; replaced with the same body', v_sig;
    return;
  end if;
  if md5(v_src) <> 'ca8992285f517c4c23768b8526aa65ad' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007010000 expects (md5 %)', v_sig, md5(v_src);
  end if;
end
$guard$;

create or replace function public.erp_approval_audit(p_object_type text default null, p_limit integer default 200)
returns jsonb
language plpgsql
set search_path = ''
as $function$
declare
  v_tenant uuid;
  v_limit  integer := least(greatest(coalesce(p_limit, 200), 1), 1000);
  v_out    jsonb;
begin
  perform erp.authorise('administration.audit_read');
  v_tenant := erp.current_tenant_id();

  -- Every approval that was asked for, step by step, from the request and its
  -- tasks (20261007010000, J-29). The routing stamp this used to read is
  -- written only when somebody presses "Work out who approves", and a
  -- submitted document never writes one. Every table names the organisation,
  -- so the row policies are met by the same condition rather than row by row.
  select coalesce(jsonb_agg(r.j order by r.requested_at desc, r.request_id, r.seq, r.step_code),
                  '[]'::jsonb)
    into v_out
    from (
      select jsonb_build_object(
               'request_id', q.id,
               'requested_at', q.requested_at,
               'request_status', q.status,
               'object_type', q.object_type,
               'object_id', q.object_id,
               'document_number', d.document_number,
               'document_type_name', dt.name,
               'value_minor', q.value_at_approval::bigint,
               'currency', nullif(q.context ->> 'currency', ''),
               'requester', rq.display_name,
               'seq', g.seq,
               'step_code', g.step_code,
               'step_name', st.name,
               'approver', g.went_to,
               'approver_of_record', g.covering_for,
               'covered', g.covering_for is not null,
               'cover_kind', case
                               when g.delegated and g.escalated then 'delegation, escalation'
                               when g.delegated then 'delegation'
                               when g.escalated then 'escalation'
                             end) as j,
             q.requested_at, q.id as request_id, g.seq, g.step_code
        from (
          select q0.*
            from erp.approval_request q0
           where q0.tenant_id = v_tenant
             and (p_object_type is null or q0.object_type = p_object_type)
           order by q0.requested_at desc, q0.id
           limit v_limit
        ) q
        cross join lateral (
          -- One row per step: a role's step is a task for each person holding
          -- it. A task handed on (delegated, escalated) is not who the step
          -- went to in the end; the one that took it over names it.
          select t.seq, t.step_code, t.approval_step_id,
                 string_agg(distinct coalesce(au.display_name, ar.name), ', '
                            order by coalesce(au.display_name, ar.name))
                   filter (where t.status not in ('delegated', 'escalated')) as went_to,
                 string_agg(distinct coalesce(df.display_name, ef.display_name), ', '
                            order by coalesce(df.display_name, ef.display_name)) as covering_for,
                 bool_or(t.delegated_from is not null) as delegated,
                 bool_or(t.escalated_from is not null) as escalated
            from erp.approval_task t
            left join erp.app_user au on au.tenant_id = v_tenant and au.id = t.assignee_user_id
            left join erp.role ar on ar.tenant_id = v_tenant and ar.id = t.assignee_role_id
            left join erp.app_user df on df.tenant_id = v_tenant and df.id = t.delegated_from
            left join erp.approval_task et on et.tenant_id = v_tenant and et.id = t.escalated_from
            left join erp.app_user ef on ef.tenant_id = v_tenant and ef.id = et.assignee_user_id
           where t.tenant_id = v_tenant
             and t.approval_request_id = q.id
             and t.status <> 'skipped'
           group by t.seq, t.step_code, t.approval_step_id
        ) g
        left join erp.approval_step st on st.tenant_id = v_tenant and st.id = g.approval_step_id
        left join erp.document d
          on q.object_type = 'document' and d.tenant_id = v_tenant and d.id = q.object_id
        left join erp.document_type dt on dt.tenant_id = v_tenant and dt.id = d.document_type_id
        left join erp.app_user rq on rq.tenant_id = v_tenant and rq.id = q.requested_by
       order by q.requested_at desc, q.id, g.seq, g.step_code
       limit v_limit
    ) r;

  return v_out;
end;
$function$;

revoke all on function public.erp_approval_audit(text, integer) from public, anon;

comment on function public.erp_approval_audit(text, integer) is
  'Approval history (Governance): every approval request in the organisation, newest first, one row per step it '
  'reached, with who it went to and who was covered for, read from erp.approval_request and erp.approval_task '
  '(20261007010000, J-29). Skipped steps are left out. Needs administration.audit_read.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.approval_history_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_cases   integer := 0;
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1        uuid := gen_random_uuid();
  a2        uuid := gen_random_uuid();
  a3        uuid := gen_random_uuid();
  v_owner   text := current_user;
  v_step    text := 'provisioning';
  v_state   text;
  rb        record;
  r2        record;
  res       jsonb;
  v_entity  uuid; v_site uuid; v_uom uuid; v_item uuid; v_sup uuid;
  v_req     uuid; v_req2 uuid; v_doc3 uuid;
  v_request uuid; v_request2 uuid; v_theirs uuid;
  v_task    uuid;
  v_role    uuid;
  v_other   uuid; v_other_tok text;
  v_admin   text;
  v_number  text;
  v_value   bigint;
  v_audit   jsonb;
  v_signed  jsonb;
  v_rows    jsonb;
  v_row     jsonb;
  v_steps   integer;
  v_names   text;
  v_n       integer;
  v_m       integer;
  v_x       text;
begin
  begin
    -- ── The fixture ───────────────────────────────────────────────────────────
    v_step := 'an organisation that buys, not yet live';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzahs-' || v_tag, 'Approval History Suite',
      'admin@zzahs-' || v_tag || '.test', 'History Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzahs-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    res := erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_entity := (res ->> 'entity_id')::uuid;
    v_site := (res ->> 'site_id')::uuid;
    select u.display_name into v_admin from erp.app_user u
     where u.tenant_id = rb.tenant_id and u.id = rb.admin_user_id;
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base and u.uom_class = 'quantity' and u.status = 'active'
     order by u.code limit 1;
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZAHSSUP', 'Approval History Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZAHSWID', 'Approval History Widget', v_uom, 'active') returning id into v_item;

    -- Somebody who reads purchasing and approves nothing.
    v_step := 'a second person, who may not read the audit';
    insert into erp.role (tenant_id, code, name, status)
    values (rb.tenant_id, 'zz_ahs_reader', 'Approval history reader', 'active') returning id into v_role;
    insert into erp.role_permission (tenant_id, role_id, permission_code) values
      (rb.tenant_id, v_role, 'procurement.read');
    res := public.erp_invite_principal('reader@zzahs-' || v_tag || '.test', 'Rita Reader');
    v_other := (res ->> 'app_user_id')::uuid;
    v_other_tok := res ->> 'token';
    perform erp.grant_role(v_other, 'zz_ahs_reader', null, null, 'reads and approves nothing');
    insert into auth.users (id, email) values (a2, 'reader@zzahs-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_other_tok);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- A requisition submitted for approval. Nobody presses "Work out who
    -- approves", so nothing is stamped.
    v_step := 'a requisition submitted for approval';
    v_req := erp.open_document('requisition', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_req, v_item, 10, 1000, 'ten widgets');
    perform erp.transition_document(v_req, 'submit', null);
    select q.id, q.value_at_approval::bigint into v_request, v_value
      from erp.approval_request q
     where q.tenant_id = rb.tenant_id and q.object_type = 'document' and q.object_id = v_req;
    select d.document_number into v_number from erp.document d
     where d.tenant_id = rb.tenant_id and d.id = v_req;
    select count(*) into v_steps
      from (select distinct t.seq, t.step_code from erp.approval_task t
             where t.tenant_id = rb.tenant_id and t.approval_request_id = v_request
               and t.status <> 'skipped') s;
    select string_agg(distinct u.display_name, ', ' order by u.display_name) into v_names
      from erp.approval_task t
      join erp.app_user u on u.tenant_id = t.tenant_id and u.id = t.assignee_user_id
     where t.tenant_id = rb.tenant_id and t.approval_request_id = v_request
       and t.status <> 'skipped';

    -- ── 1. It is in the history, read as the screen reads it ─────────────────
    v_step := 'reading the history';
    v_audit := public.erp_approval_audit(null, 200);
    select coalesce(jsonb_agg(e), '[]'::jsonb) into v_rows
      from jsonb_array_elements(v_audit) e where e ->> 'request_id' = v_request::text;
    v_row := v_rows -> 0;
    set local role authenticated;
    v_signed := public.erp_approval_audit(null, 200);
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'a submitted requisition is in the history, a row for each step it reached, though nothing was stamped';
    passed := v_request is not null and v_steps > 0
          and jsonb_array_length(v_rows) = v_steps
          and not exists (select 1 from erp.approval_routing_stamp s
                           where s.tenant_id = rb.tenant_id and s.object_id = v_req)
          and v_row ->> 'object_id' = v_req::text
          and v_row ->> 'document_number' = v_number
          and v_row ->> 'document_type_name' is not null
          and (v_row ->> 'value_minor')::bigint = v_value and v_value = 10000
          and v_row ->> 'requester' = v_admin
          and v_row ->> 'approver' is not null
          and (select string_agg(distinct x, ', ' order by x)
                 from jsonb_array_elements(v_rows) e,
                      regexp_split_to_table(e ->> 'approver', ', ') x) = v_names
          and coalesce(v_row ->> 'step_name', v_row ->> 'step_code') is not null
          and not (v_row ->> 'covered')::boolean
          and v_signed = v_audit;
    detail := coalesce(v_state, format('%s row(s) for %s step(s); %s for %s by %s, went to %s (tasks: %s); signed in alike %s',
                jsonb_array_length(v_rows), v_steps, v_row ->> 'document_number', v_row ->> 'value_minor',
                v_row ->> 'requester', v_row ->> 'approver', v_names, v_signed = v_audit));
    return next;

    -- ── 2. A step handed on says who took it and who was covered for ────────
    v_step := 'delegating the step';
    select t.id into v_task from erp.approval_task t
     where t.tenant_id = rb.tenant_id and t.approval_request_id = v_request
       and t.status = 'pending' and t.assignee_user_id = rb.admin_user_id
     order by t.seq limit 1;
    perform erp.delegate_approval_task(v_task, v_other, 'away this week');
    select e into v_row from jsonb_array_elements(public.erp_approval_audit(null, 200)) e
     where e ->> 'request_id' = v_request::text
       and (e ->> 'seq')::int = (select t.seq from erp.approval_task t where t.id = v_task)
       and e ->> 'step_code' = (select t.step_code from erp.approval_task t where t.id = v_task);
    v_cases := v_cases + 1;
    case_name := 'a delegated step names who it went to and who they covered for';
    passed := v_task is not null
          and strpos(v_row ->> 'approver', 'Rita Reader') > 0
          and v_row ->> 'approver_of_record' = v_admin
          and (v_row ->> 'covered')::boolean
          and v_row ->> 'cover_kind' = 'delegation';
    detail := coalesce(v_state, format('task %s; went to %s, covering for %s (%s)',
                coalesce(v_task::text, 'none assigned to the administrator'), v_row ->> 'approver',
                v_row ->> 'approver_of_record', v_row ->> 'cover_kind'));
    return next;

    -- ── 3. A routing stamp is not an approval ────────────────────────────────
    v_step := 'stamping a requisition that was never submitted';
    -- A named approver, so the stamp resolves a step the old reading would
    -- have listed.
    insert into erp.approver_assignment (tenant_id, subject_kind, subject_id, object_type,
                                         approver_user_id, reason)
    values (rb.tenant_id, 'principal', rb.admin_user_id, 'requisition', v_other,
            'the approval history suite');
    v_req2 := erp.open_document('requisition', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_req2, v_item, 2, 1000, 'two widgets');
    select jsonb_array_length(public.erp_approval_audit(null, 1000)) into v_n;
    perform public.erp_stamp_document_approval(v_req2);
    select jsonb_array_length(public.erp_approval_audit(null, 1000)) into v_m;
    v_cases := v_cases + 1;
    case_name := 'a routing stamp alone adds nothing to the history: it records what the rules would answer, not an approval';
    passed := v_n = v_m
          and exists (select 1 from erp.approval_routing_stamp s
                       where s.tenant_id = rb.tenant_id and s.object_id = v_req2
                         and jsonb_array_length(s.resolved_chain -> 'steps') = 1)
          and not exists (select 1 from jsonb_array_elements(public.erp_approval_audit(null, 1000)) e
                           where e ->> 'object_id' = v_req2::text);
    detail := coalesce(v_state, format('%s row(s) before the stamp, %s after', v_n, v_m));
    return next;

    -- ── 4. The filter and the limit ──────────────────────────────────────────
    v_step := 'submitting the stamped requisition, then filtering and limiting';
    perform erp.transition_document(v_req2, 'submit', null);
    v_cases := v_cases + 1;
    case_name := 'the history filters by what is approved and stops at the limit asked for';
    passed := jsonb_array_length(public.erp_approval_audit('document', 200)) > v_m
          and v_m > 0
          and jsonb_array_length(public.erp_approval_audit('zz_nothing_is_this', 200)) = 0
          and jsonb_array_length(public.erp_approval_audit(null, 1)) = 1
          and jsonb_array_length(public.erp_approval_audit(null, 0)) = 1;
    detail := coalesce(v_state, format('documents %s, of a kind nobody raises %s, limit 1 %s',
                jsonb_array_length(public.erp_approval_audit('document', 200)),
                jsonb_array_length(public.erp_approval_audit('zz_nothing_is_this', 200)),
                jsonb_array_length(public.erp_approval_audit(null, 1))));
    return next;

    -- ── 5. Another organisation's approvals ──────────────────────────────────
    v_step := 'a second organisation that asks for an approval';
    perform set_config('request.jwt.claims', '', true);
    select * into r2 from erp.provision_tenant(
      'zzahs2-' || v_tag, 'Approval History Elsewhere',
      'admin@zzahs2-' || v_tag || '.test', 'Elsewhere Admin');
    update erp.environment set is_live = false where tenant_id = r2.tenant_id and is_self;
    insert into auth.users (id, email) values (a3, 'admin@zzahs2-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(r2.admin_token);
    res := erp.ensure_demo_configuration(r2.tenant_id, r2.admin_user_id);
    insert into erp.party (tenant_id, code, name, status)
    values (r2.tenant_id, 'ZAHSSUP', 'Elsewhere Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r2.tenant_id, v_sup, 'supplier', 'active');
    select u.id into v_uom from erp.uom u
     where u.tenant_id = r2.tenant_id and u.is_base and u.uom_class = 'quantity' and u.status = 'active'
     order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r2.tenant_id, 'ZAHSWID', 'Elsewhere Widget', v_uom, 'active') returning id into v_item;
    v_doc3 := erp.open_document('requisition', v_sup, (res ->> 'entity_id')::uuid, (res ->> 'site_id')::uuid);
    perform erp.add_document_line(v_doc3, v_item, 1, 1000, 'one widget');
    perform erp.transition_document(v_doc3, 'submit', null);
    select q.id into v_theirs from erp.approval_request q
     where q.tenant_id = r2.tenant_id and q.object_id = v_doc3;
    select count(*) into v_n from jsonb_array_elements(public.erp_approval_audit(null, 1000)) e
     where e ->> 'request_id' = v_theirs::text;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select count(*) into v_m from jsonb_array_elements(public.erp_approval_audit(null, 1000)) e
     where e ->> 'request_id' = v_theirs::text;
    v_cases := v_cases + 1;
    case_name := 'another organisation''s approvals are in its own history and not in this one';
    passed := v_theirs is not null and v_n > 0 and v_m = 0;
    detail := coalesce(v_state, format('theirs: %s row(s) there, %s here', v_n, v_m));
    return next;

    -- ── 6. Somebody without the audit permission ─────────────────────────────
    v_step := 'reading the history without the audit permission';
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    v_x := null;
    begin
      perform public.erp_approval_audit(null, 200);
      v_x := 'read';
    exception when others then v_x := left(sqlerrm, 200);
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'somebody without administration.audit_read is refused the history';
    passed := v_x like 'CLOVEERP_PERMISSION_DENIED: administration.audit_read%';
    detail := coalesce(v_state, v_x);
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_APPROVAL_HISTORY_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code in ('zzahs-' || v_tag, 'zzahs2-' || v_tag))
     or exists (select 1 from auth.users u where u.id in (a1, a2, a3)) then
    raise exception 'CLOVEERP_APPROVAL_HISTORY_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.approval_history_suite() from public, anon;

comment on function erp_test.approval_history_suite() is
  'Approval history reads the requests (20261007010000, J-29): a submitted requisition is in it a row a step '
  'though nothing was stamped, read alike signed in; a delegated step names who took it and who was covered for; '
  'a stamp alone adds nothing; the filter and limit hold; another organisation''s approvals are not read; and '
  'somebody without administration.audit_read is refused.';

create or replace function erp_test.assert_approval_history_suite()
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
    from erp_test.approval_history_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_APPROVAL_HISTORY_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Approval history would miss approvals that were asked for, or show what was never asked. Read the case that failed.';
  end if;
  if v_total <> 6 then
    raise exception 'CLOVEERP_APPROVAL_HISTORY_SUITE_SHRANK: % case(s), expected 6', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('approval history: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_approval_history_suite() from public, anon;

comment on function erp_test.assert_approval_history_suite() is
  'Approval history lists every approval asked for, step by step, from the requests and not the routing stamps (20261007010000).';

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
