set lock_timeout = '30s';

-- =============================================================================
-- 20261006061000  An approval keeps its note
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-126). Three notes a
-- person typed were kept nowhere anybody could read them again:
--
--   (a) An administrator approving an order with a note: erp.transition_document
--       hands the note to the move only. erp.require_document_approval decides
--       the tasks still waiting through erp.approve_request_as_administrator,
--       which writes a fixed "Approved as administrator" on each task and
--       "Approved by an administrator" on the request, so the decision said
--       nothing the administrator wrote. Somebody who is not an administrator
--       has their note kept on their decision (erp.decide_own_approval_tasks).
--   (b) The reason a prepayment was asked for: erp.order_prepayment answers
--       it and the order's page never drew it. A screen change only.
--   (c) Why a shipping notice was cancelled: erp.cancel_shipping_notice keeps
--       it, and erp.shipping_notice, which every notice on a page is read
--       through, does not answer it.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.approve_request_as_administrator(request, note): the note, where
--      one was typed, is the comment on every task the administrator decides
--      and the request's decision note. Without one, the words are as before.
--   B. erp.require_document_approval(document, move, note), and
--      erp.transition_document passes it the reason typed with the press.
--   C. erp.shipping_notice answers cancelled_reason.
--   D. erp_test.approval_keeps_its_note_suite.
--
-- The two routines change their arguments, so each is dropped and created
-- again in this transaction with its new note defaulting to null; every
-- caller names the arguments it had and is answered the same. Neither is a
-- door. The order's page and a notice draw the two reasons with the words
-- "Reason" and "Why it is cancelled" they already use.
--
-- On production: three functions are replaced and one is patched. No table
-- is altered and no row is changed; decisions taken before keep the words
-- they were given.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. An administrator's decision keeps what they typed
-- ─────────────────────────────────────────────────────────────────────────────

do $admin$
declare
  v_def  text;
  v_src  text;
  v_note text;
  v_old_head constant text := 'erp.approve_request_as_administrator(p_request_id uuid)';
  v_new_head constant text := 'erp.approve_request_as_administrator(p_request_id uuid, p_note text DEFAULT NULL::text)';
  v_old  constant text := $o$               comment = case when t.assignee_user_id is not distinct from v_actor
                              then 'Approved as administrator'
                              else 'Approved as administrator, for the person asked' end
                         || case when v_own then ', on their own request' else '' end,
$o$;
  v_new  constant text := $n$               -- What the administrator typed, where they typed something
               -- (20261006061000, J-126); otherwise what the decision was.
               comment = coalesce(nullif(btrim(p_note), ''),
                         case when t.assignee_user_id is not distinct from v_actor
                              then 'Approved as administrator'
                              else 'Approved as administrator, for the person asked' end
                         || case when v_own then ', on their own request' else '' end),
$n$;
  v_old2 constant text := $o$             decision_note = 'Approved by an administrator', updated_at = now()
$o$;
  v_new2 constant text := $n$             decision_note = coalesce(nullif(btrim(p_note), ''), 'Approved by an administrator'),
             updated_at = now()
$n$;
begin
  if to_regprocedure('erp.approve_request_as_administrator(uuid,text)') is not null then
    raise notice 'erp.approve_request_as_administrator already takes the note; left as it is';
    return;
  end if;
  v_src := (select p.prosrc from pg_catalog.pg_proc p
             where p.oid = 'erp.approve_request_as_administrator(uuid)'::regprocedure);
  v_def := pg_catalog.pg_get_functiondef('erp.approve_request_as_administrator(uuid)'::regprocedure);
  v_note := obj_description('erp.approve_request_as_administrator(uuid)'::regprocedure, 'pg_proc');
  if md5(v_src) <> 'ab6b48023f46fa80da0d0b567f0ead9e' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.approve_request_as_administrator is not the body 20261006061000 expects (md5 %)', md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1
     or (length(v_def) - length(replace(v_def, v_old_head, ''))) / length(v_old_head) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.approve_request_as_administrator anchor found other than once';
  end if;
  drop function erp.approve_request_as_administrator(uuid);
  execute replace(replace(replace(v_def, v_old_head, v_new_head), v_old, v_new), v_old2, v_new2);
  execute format('comment on function erp.approve_request_as_administrator(uuid, text) is %L',
                 coalesce(v_note, '') || ' The note the administrator typed, where they typed one, is the '
                 'comment on each task and the request''s decision note (20261006061000).');
end
$admin$;

revoke all on function erp.approve_request_as_administrator(uuid, text) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The press hands the note on
-- ─────────────────────────────────────────────────────────────────────────────

do $hold$
declare
  v_def  text;
  v_src  text;
  v_note text;
  v_old_head constant text := 'erp.require_document_approval(p_document_id uuid, p_transition_code text)';
  v_new_head constant text := 'erp.require_document_approval(p_document_id uuid, p_transition_code text, p_note text DEFAULT NULL::text)';
  v_old  constant text := $o$    perform erp.approve_request_as_administrator(q.id);
$o$;
  v_new  constant text := $n$    -- With what they typed, if anything (20261006061000).
    perform erp.approve_request_as_administrator(q.id, p_note);
$n$;
begin
  if to_regprocedure('erp.require_document_approval(uuid,text,text)') is not null then
    raise notice 'erp.require_document_approval already takes the note; left as it is';
    return;
  end if;
  v_src := (select p.prosrc from pg_catalog.pg_proc p
             where p.oid = 'erp.require_document_approval(uuid,text)'::regprocedure);
  v_def := pg_catalog.pg_get_functiondef('erp.require_document_approval(uuid,text)'::regprocedure);
  v_note := obj_description('erp.require_document_approval(uuid,text)'::regprocedure, 'pg_proc');
  if md5(v_src) <> '0274245e15d2b20f104b95e3f0b60881' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.require_document_approval is not the body 20261006061000 expects (md5 %)', md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1
     or (length(v_def) - length(replace(v_def, v_old_head, ''))) / length(v_old_head) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.require_document_approval anchor found other than once';
  end if;
  drop function erp.require_document_approval(uuid, text);
  execute replace(replace(v_def, v_old_head, v_new_head), v_old, v_new);
  execute format('comment on function erp.require_document_approval(uuid, text, text) is %L',
                 coalesce(v_note, '') || ' The reason typed with the press is the administrator''s note on '
                 'the tasks they decide (20261006061000).');
end
$hold$;

revoke all on function erp.require_document_approval(uuid, text, text) from public, anon;

do $press$
declare
  v_sig  constant text := 'erp.transition_document(uuid,text,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  perform erp.require_document_approval(p_document_id, p_transition_code);
$o$;
  v_new  constant text := $n$  -- With the reason typed, which an administrator's decision keeps
  -- (20261006061000).
  perform erp.require_document_approval(p_document_id, p_transition_code, p_reason);
$n$;
begin
  if strpos(v_src, '20261006061000') > 0 then
    raise notice '% already hands the note on; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'c5a0edd3f823df640aca74bf8b0ede71' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006061000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$press$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. A cancelled notice says why
-- ─────────────────────────────────────────────────────────────────────────────

do $notice$
declare
  v_sig  constant text := 'erp.shipping_notice(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$           'differences', n.differences,
$o$;
  v_new  constant text := $n$           'differences', n.differences,
           -- Why the buyer cancelled it (20261006061000, J-126).
           'cancelled_reason', n.cancelled_reason,
$n$;
begin
  if strpos(v_src, '20261006061000') > 0 then
    raise notice '% already answers why it was cancelled; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '6544e19ea0a74295a751d0179dae6e73' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006061000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$notice$;

comment on function erp.shipping_notice(uuid) is
  'A shipping notice as a page reads it (20261005000000): its dates, carrier, lines, cartons, receipt and '
  'differences, and why it was cancelled once it is (20261006061000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.approval_keeps_its_note_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_cases  integer := 0;
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();   -- the administrator, who buys
  a2       uuid := gen_random_uuid();   -- the second administrator, who is asked
  r        record;
  res      jsonb;
  v_second uuid;
  v_tok    text;
  cs_fin   uuid;
  cs_proc  uuid;
  cs_ctrl  uuid;
  v_step   text := 'starting';
  v_state  text;
  v_uom    uuid;
  v_site   uuid;
  v_sup    uuid;
  v_item   uuid;
  v_po     uuid;
  v_line   uuid;
  v_req    uuid;
  v_to     text;
  v_comments text;
  v_decision text;
  v_to2    text;
  v_comments2 text;
  v_notice jsonb;
  v_read   jsonb;
begin
  begin
    -- ── A live organisation whose administrators approve their own ─────────
    v_step := 'a live organisation is provisioned';
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.job_principal_id', '', true);
    perform set_config('request.jwt.claims', '', true);
    select * into r from erp.provision_tenant(
      'zz-note-' || v_hex, 'Approval note suite',
      'admin@zz-note-' || v_hex || '.test', 'Note Admin');
    insert into auth.users (id, email)
    values (a1, 'admin@zz-note-' || v_hex || '.test'),
           (a2, 'second@zz-note-' || v_hex || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zz-note-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid;
    v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

    v_step := 'finance and procurement are installed';
    cs_fin := erp.configure_finance();
    select (d ->> 'lifecycle_change_set_id')::uuid, (d ->> 'controls_change_set_id')::uuid
      into cs_proc, cs_ctrl
      from public.erp_configure_procurement(1000000, 'purchasing') d;
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(cs_fin);
    perform erp.promote_change_set(cs_fin);
    perform erp.approve_change_set(cs_proc);
    perform erp.promote_change_set(cs_proc);
    perform erp.approve_change_set(cs_ctrl);
    perform erp.promote_change_set(cs_ctrl);
    perform erp.grant_role(r.admin_user_id, 'purchasing', null, null, 'buys');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.grant_role(v_second, 'purchasing', null, null, 'approves orders');

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

    -- ── 1. Approved with a note ────────────────────────────────────────────
    v_step := 'the administrator approves their own order with a note';
    v_po := erp.open_document('purchase_order', v_sup, null, v_site);
    v_line := erp.add_document_line(v_po, v_item, 10, 5000, 'Ten widgets');
    perform erp.transition_document(v_po, 'submit');
    select q.id into v_req from erp.approval_request q
     where q.tenant_id = r.tenant_id and q.object_type = 'document' and q.object_id = v_po and q.status = 'pending';
    v_to := erp.transition_document(v_po, 'approve', '  The line is down until these arrive ');
    select string_agg(distinct t.comment, ' | '), min(q.decision_note)
      into v_comments, v_decision
      from erp.approval_task t
      join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
     where t.tenant_id = r.tenant_id and t.approval_request_id = v_req
       and t.status = 'approved' and t.decided_via = 'administrator';

    v_cases := v_cases + 1;
    case_name := 'an administrator''s note on Approve is the comment on the tasks they decide and the request''s decision';
    passed := v_state is null and v_to = 'approved'
          and v_comments = 'The line is down until these arrive'
          and v_decision = 'The line is down until these arrive';
    detail := coalesce(v_state, format('the order is %s; tasks say %s; the request says %s', v_to, v_comments, v_decision));
    return next;

    -- ── 2. Approved without one ────────────────────────────────────────────
    v_step := 'the administrator approves another order without a note';
    v_po := erp.open_document('purchase_order', v_sup, null, v_site);
    perform erp.add_document_line(v_po, v_item, 2, 5000, 'Two widgets');
    perform erp.transition_document(v_po, 'submit');
    select q.id into v_req from erp.approval_request q
     where q.tenant_id = r.tenant_id and q.object_type = 'document' and q.object_id = v_po and q.status = 'pending';
    v_to2 := erp.transition_document(v_po, 'approve');
    select string_agg(distinct t.comment, ' | ') into v_comments2
      from erp.approval_task t
     where t.tenant_id = r.tenant_id and t.approval_request_id = v_req and t.decided_via = 'administrator';

    v_cases := v_cases + 1;
    case_name := 'without a note, the tasks say they were approved as administrator, as before';
    passed := v_state is null and v_to2 = 'approved'
          and v_comments2 = 'Approved as administrator, for the person asked, on their own request';
    detail := coalesce(v_state, format('the order is %s; tasks say %s', v_to2, v_comments2));
    return next;

    -- ── 3. A cancelled notice says why ─────────────────────────────────────
    v_step := 'the first order is sent, a notice recorded and cancelled';
    v_po := (select q.object_id from erp.approval_request q
              where q.tenant_id = r.tenant_id and q.decision_note = 'The line is down until these arrive');
    perform erp.transition_document(v_po, 'send');
    v_notice := erp.record_buyer_shipping_notice(v_po, jsonb_build_object(
                  'expected_arrival', (current_date + 3)::text,
                  'lines', jsonb_build_array(jsonb_build_object('order_line_id', v_line, 'quantity', 4))));
    perform erp.cancel_shipping_notice((v_notice ->> 'notice_id')::uuid, 'The supplier split the delivery');
    v_read := erp.shipping_notice((v_notice ->> 'notice_id')::uuid);

    v_cases := v_cases + 1;
    case_name := 'a cancelled shipping notice answers why it was cancelled, and an open one answers nothing';
    passed := v_state is null and v_notice ? 'cancelled_reason' and v_notice -> 'cancelled_reason' = 'null'::jsonb
          and v_read ->> 'status' = 'cancelled'
          and v_read ->> 'cancelled_reason' = 'The supplier split the delivery';
    detail := coalesce(v_state, format('open %s; cancelled %s', v_notice -> 'cancelled_reason', v_read -> 'cancelled_reason'));
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
    raise exception 'CLOVEERP_APPROVAL_NOTE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.approval_keeps_its_note_suite() from public, anon;

comment on function erp_test.approval_keeps_its_note_suite() is
  'An approval keeps its note (20261006061000, J-126): an administrator''s note on Approve is the comment on '
  'the tasks they decide and the request''s decision note, the fixed words stay where nothing was typed, and a '
  'cancelled shipping notice answers why.';

create or replace function erp_test.assert_approval_keeps_its_note_suite()
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
    from erp_test.approval_keeps_its_note_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_APPROVAL_NOTE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A note somebody typed was not kept where it is read again. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_APPROVAL_NOTE_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('approval keeps its note: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_approval_keeps_its_note_suite() from public, anon;

comment on function erp_test.assert_approval_keeps_its_note_suite() is
  'An administrator''s note on Approve, and why a shipping notice was cancelled, are kept where they are read '
  'again (20261006061000).';

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
