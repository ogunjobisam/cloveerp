set lock_timeout = '30s';

-- =============================================================================
-- 20260922240000  An approval that still holds is not asked for again
-- -----------------------------------------------------------------------------
-- W1 of the simplification plan: "erp.check_reapproval_required() is called by
-- nothing. Wire it into the two places that request approval for a document."
--
-- Those two places are the submit arm of erp.transition_document() and the
-- require_approval effect in erp.execute_effects(). They are mutually
-- exclusive — the submit arm stands down when the transition declares the
-- effect — so a submitted document asks exactly once, and both now ask through
-- one routine.
--
-- ── WHAT WAS DEAD, AND WHAT IT COST ──────────────────────────────────────────
--
-- erp.check_reapproval_required() reads the standing approval on an object,
-- rebuilds the material fingerprint from the context in front of it, and says
-- whether the decision still covers it. It reads three pieces of configuration
-- to do that:
--
--   approval_chain_version.material_fields — the facts an approval was about;
--   approval_chain_version.tolerance_pct and tolerance_absolute — how far the
--   value may move before the decision is stale;
--   approval.reapproval_tolerance — the organisation's own figures where the
--   chain leaves them null, including reapprove_on_supplier_change.
--
-- Every one of those is filled by the packs and by the onboarding interview,
-- and until this migration not one of them changed anything, because the only
-- caller of the routine that reads them was a suite. erp.request_approval()
-- superseded the standing approval and asked again, every time, whatever had
-- or had not changed.
--
-- ── THE TWO WAYS AN APPROVAL CAN STILL HOLD ──────────────────────────────────
--
-- 1. The document's own approval. A purchase order is approved, a line is
--    amended, it is submitted again. Whether that needs a second decision is
--    the exact question the tolerances are configured to answer, and the answer
--    was always "yes, ask again". Now the standing approval is returned
--    unchanged when nothing material moved: nothing is superseded, no task is
--    raised, and the request that governs the document is the one a person
--    actually decided.
--
-- 2. The approval on the document it was raised from. erp.document_relation
--    points from the child to the parent, so the parent is to_document_id, and
--    only three kinds carry a decision forward: converts, fulfils and invoices
--    are the same commitment taken a step further. A credit, a return, a
--    correction and a consolidation are decisions of their own and are not
--    asked. Where the parent's approval covers the child, the child gets an
--    approved request of its own naming the parent.
--
--    That second arm is wired and dormant in the configuration the packs ship,
--    and it is worth saying so rather than letting somebody discover it. Only
--    purchase_order and sales_order carry an approval_chain_code, and both are
--    the first document in their chain — a requisition and a quotation carry no
--    chain, so there is no decision on the parent to inherit. It fires the day
--    an organisation puts a chain on requisitions, which is a thing the
--    approval chain authoring screens already let them do.
--
-- ── WHY THE INHERITANCE IS RECORDED AND NOT SKIPPED ──────────────────────────
--
-- erp.require_document_approval() returns without refusing when a document has
-- no approval request at all — "submitted before its type had a chain: nothing
-- was asked, nothing holds it". So a child that silently skipped the request
-- would be indistinguishable from a document nothing was ever asked about, and
-- would approve on its permission alone. The inherited approval is therefore
-- written down, carrying the parent's chain and chain version, with a decision
-- note that names the parent and the reason the check gave. The trail says
-- where the decision came from.
--
-- The first arm needs no such row: the document already has its own approved
-- request, and the honest record is that one, untouched.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The routine both doors ask
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.request_document_approval_or_inherit(
  p_document_id uuid,
  p_context     jsonb default '{}'::jsonb,
  p_entity_id   uuid default null,
  p_site_id     uuid default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant    uuid := erp.require_tenant_id();
  v_required  boolean;
  v_reason    text;
  v_parent    uuid;
  v_parent_no text;
  v_kind      text;
  v_req       erp.approval_request%rowtype;
  v_cv        erp.approval_chain_version%rowtype;
  v_new       uuid;
begin
  -- ── 1. Does this document's own approval still cover it? ──────────────────
  --
  -- erp.check_reapproval_required() answers 'no standing approval' when there
  -- is none, so the ordinary first submission falls straight through.
  select c.required, c.reason into v_required, v_reason
    from erp.check_reapproval_required('document', p_document_id, p_context) c;

  if not coalesce(v_required, true) then
    select ar.id into v_new
      from erp.approval_request ar
     where ar.tenant_id = v_tenant
       and ar.object_type = 'document'
       and ar.object_id = p_document_id
       and ar.status = 'approved'
     order by ar.decided_at desc
     limit 1;
    return v_new;
  end if;

  -- ── 2. Does the approval on the document it was raised from? ──────────────
  select r.to_document_id, pd.document_number, r.relation_kind::text
    into v_parent, v_parent_no, v_kind
    from erp.document_relation r
    join erp.document pd on pd.tenant_id = r.tenant_id and pd.id = r.to_document_id
   where r.tenant_id = v_tenant
     and r.from_document_id = p_document_id
     and r.relation_kind in ('converts', 'fulfils', 'invoices')
   order by r.created_at, r.id
   limit 1;

  if v_parent is not null then
    select c.required, c.reason into v_required, v_reason
      from erp.check_reapproval_required('document', v_parent, p_context) c;

    if not coalesce(v_required, true) then
      select * into v_req
        from erp.approval_request ar
       where ar.tenant_id = v_tenant
         and ar.object_type = 'document'
         and ar.object_id = v_parent
         and ar.status = 'approved'
       order by ar.decided_at desc
       limit 1;

      select * into v_cv
        from erp.approval_chain_version
       where id = v_req.approval_chain_version_id;

      insert into erp.approval_request (
        tenant_id, object_type, object_id, object_version, entity_id, site_id,
        approval_chain_id, approval_chain_version_id, context,
        material_fingerprint, value_at_approval, requested_by,
        status, decided_at, decision_note)
      values (
        v_tenant, 'document', p_document_id, 1, p_entity_id, p_site_id,
        v_req.approval_chain_id, v_req.approval_chain_version_id, p_context,
        erp.material_fingerprint(p_context, v_cv.material_fields, v_cv.value_field),
        case when v_cv.value_field is null then null
             else (p_context #>> string_to_array(v_cv.value_field, '.'))::numeric end,
        erp.current_principal_id(),
        'approved', now(),
        format('carried from %s, which was approved and %s', v_parent_no, v_reason))
      returning id into v_new;

      return v_new;
    end if;
  end if;

  -- ── 3. Nothing covers it, so it is asked for ──────────────────────────────
  return erp.request_approval('document', p_document_id, p_context, 1,
                              p_entity_id, p_site_id);
end;
$$;

comment on function erp.request_document_approval_or_inherit(uuid, jsonb, uuid, uuid) is
  'Asks for a document approval unless one already covers it: its own standing '
  'approval where nothing material has moved since, or the approval on the '
  'document it was converted, fulfilled or invoiced from. An inherited '
  'approval is written down naming what it came from, because a document with '
  'no request at all is one erp.require_document_approval() does not hold.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The submit arm of the document door
-- ═════════════════════════════════════════════════════════════════════════════

do $submit$
declare
  v_sig constant text := 'erp.transition_document(uuid, text, text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'    perform erp.request_approval(''document'', p_document_id, v_ctx, 1,\n'
    || E'                                 d.entity_id, d.site_id);\n';
  v_new constant text :=
       E'    -- Unless one already holds it (20260922240000): its own, where nothing\n'
    || E'    -- material has moved since it was given, or the one on the document this\n'
    || E'    -- was raised from.\n'
    || E'    perform erp.request_document_approval_or_inherit(p_document_id, v_ctx,\n'
    || E'                                                     d.entity_id, d.site_id);\n';
  v_hits integer;
begin
  if position('request_document_approval_or_inherit' in v_def) > 0 then
    raise exception 'CLOVEERP_SUBMIT_UNRECOGNISED: % already asks through the inheriting routine', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SUBMIT_UNRECOGNISED: % asks for approval on submit % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$submit$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. And the require_approval effect
-- ═════════════════════════════════════════════════════════════════════════════
--
-- p_data here is the transition's guard data, which for a document moved
-- through erp.transition_document() is the document transition context — the
-- same jsonb the submit arm passes. So the check reads the same facts whichever
-- of the two doors asked.

do $effect$
declare
  v_sig constant text :=
    'erp.execute_effects(text, uuid, jsonb, jsonb, uuid, uuid, text, text, text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
    E'            perform erp.request_approval(''document'', p_object_id, coalesce(p_data, ''{}''::jsonb), 1, p_entity_id, p_site_id);\n';
  v_new constant text :=
       E'            -- Unless one already holds it (20260922240000).\n'
    || E'            perform erp.request_document_approval_or_inherit(\n'
    || E'              p_object_id, coalesce(p_data, ''{}''::jsonb), p_entity_id, p_site_id);\n';
  v_hits integer;
begin
  if position('request_document_approval_or_inherit' in v_def) > 0 then
    raise exception 'CLOVEERP_EFFECT_UNRECOGNISED: % already asks through the inheriting routine', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_EFFECT_UNRECOGNISED: % raises a document approval % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$effect$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The case that matters most is the third: an approval that still holds is not
-- asked for again. The one after it is what keeps that honest — the moment the
-- value moves, it is asked for again — because the failure mode of this node is
-- not that nothing inherits, it is that everything does.
--
-- The last case before the undo reads the two deployed doors. A routine
-- nothing calls is what this node exists to put right, and a suite that only
-- tested the routine would be as dead as the routine was.

create or replace function erp_test.inherited_approval_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hex     text := replace(gen_random_uuid()::text, '-', '');
  a1        uuid := gen_random_uuid();
  r         record;
  v_cs      uuid;
  v_uom     uuid; v_site uuid; v_sup uuid; v_item uuid;
  v_po      uuid; v_po2 uuid; v_child uuid; v_child2 uuid;
  v_ctx     jsonb;
  v_first   uuid; v_again uuid; v_moved uuid; v_carried uuid; v_own uuid;
  v_status  text; v_note text; v_number text;
  v_n       integer;
  v_cases   integer := 0;
  v_td      text; v_ee text;
  v_fixture text;
begin
  begin
  select * into r from erp.provision_tenant(
    'zz-inh-' || v_hex, 'Inherited approval suite',
    'admin@zz-inh-' || v_hex || '.test', 'Inherited Approval Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);

  v_cs := erp.configure_finance();
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  v_cs := erp.configure_inventory('average');
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  v_cs := erp.configure_procurement(100000000);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);

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
  v_po := erp.open_document('purchase_order', v_sup, r.entity_id, v_site);
  perform erp.add_document_line(v_po, v_item, 10, 1000, 'ten widgets');
  perform erp.transition_document(v_po, 'submit', 'inherited approval suite');

  select count(*) into v_n
    from erp.approval_request ar
   where ar.tenant_id = r.tenant_id and ar.object_type = 'document' and ar.object_id = v_po;
  select ar.id, ar.status::text into v_first, v_status
    from erp.approval_request ar
   where ar.tenant_id = r.tenant_id and ar.object_type = 'document' and ar.object_id = v_po
   order by ar.requested_at desc, ar.id desc
   limit 1;

  v_cases := v_cases + 1;
  case_name := 'a purchase order submitted asks for approval';
  passed := v_n = 1 and v_status = 'pending';
  detail := format('%s request(s), the newest %s', v_n, v_status);
  return next;

  -- ── 2. Decided ────────────────────────────────────────────────────────────
  perform erp_test.approve_document(v_po, 'inherited approval suite');
  select ar.status::text into v_status
    from erp.approval_request ar where ar.tenant_id = r.tenant_id and ar.id = v_first;

  v_cases := v_cases + 1;
  case_name := 'and once it is decided the document carries a standing approval';
  passed := v_status = 'approved';
  detail := format('the request is %s', v_status);
  return next;

  -- ── 3. Asked again, unchanged ─────────────────────────────────────────────
  -- The node itself. Before this migration erp.request_approval() superseded
  -- the decision and raised a fresh task here, every time.
  v_ctx := erp.document_transition_context(v_po, 'submit');
  v_again := erp.request_document_approval_or_inherit(v_po, v_ctx, r.entity_id, v_site);

  select count(*) into v_n
    from erp.approval_request ar
   where ar.tenant_id = r.tenant_id and ar.object_type = 'document' and ar.object_id = v_po;

  v_cases := v_cases + 1;
  case_name := 'asked again with nothing changed, the standing approval is what answers';
  passed := v_again = v_first
        and v_n = 1
        and not exists (select 1 from erp.approval_request ar
                         where ar.tenant_id = r.tenant_id and ar.object_id = v_po
                           and ar.status = 'pending');
  detail := format('the same request came back: %s; %s request(s) on the document',
                   v_again = v_first, v_n);
  return next;

  -- ── 4. Asked again after the value moves ──────────────────────────────────
  perform erp.add_document_line(v_po, v_item, 40, 1000, 'forty more');
  v_ctx := erp.document_transition_context(v_po, 'submit');
  v_moved := erp.request_document_approval_or_inherit(v_po, v_ctx, r.entity_id, v_site);

  select ar.status::text into v_status
    from erp.approval_request ar where ar.tenant_id = r.tenant_id and ar.id = v_moved;

  v_cases := v_cases + 1;
  case_name := 'and the moment the value moves it is asked for again';
  passed := v_moved is distinct from v_first and v_status = 'pending';
  detail := format('a new request, %s — a node that inherited this would be worse than one that inherited nothing',
                   v_status);
  return next;

  -- ── 5. The child of an approved document ──────────────────────────────────
  -- A second order, approved and left alone, and a document raised from it.
  v_po2 := erp.open_document('purchase_order', v_sup, r.entity_id, v_site);
  perform erp.add_document_line(v_po2, v_item, 10, 1000, 'ten widgets');
  perform erp.transition_document(v_po2, 'submit', 'inherited approval suite');
  perform erp_test.approve_document(v_po2, 'inherited approval suite');
  select d.document_number into v_number
    from erp.document d where d.tenant_id = r.tenant_id and d.id = v_po2;

  v_child := erp.open_document('purchase_order', v_sup, r.entity_id, v_site);
  perform erp.add_document_line(v_child, v_item, 10, 1000, 'the same ten');
  insert into erp.document_relation (tenant_id, from_document_id, to_document_id, relation_kind)
  values (r.tenant_id, v_child, v_po2, 'converts');

  v_ctx := erp.document_transition_context(v_child, 'submit');
  v_carried := erp.request_document_approval_or_inherit(v_child, v_ctx, r.entity_id, v_site);

  select ar.status::text, ar.decision_note into v_status, v_note
    from erp.approval_request ar where ar.tenant_id = r.tenant_id and ar.id = v_carried;
  select count(*) into v_n
    from erp.approval_task t where t.tenant_id = r.tenant_id and t.approval_request_id = v_carried;

  v_cases := v_cases + 1;
  case_name := 'a document raised from an approved one carries that approval, and says where it came from';
  passed := v_status = 'approved' and v_note like '%' || v_number || '%' and v_n = 0;
  detail := format('%s: %s; %s task(s) raised', v_status, coalesce(v_note, 'no note'), v_n);
  return next;

  -- ── 6. And a child that is not the same commitment ────────────────────────
  v_child2 := erp.open_document('purchase_order', v_sup, r.entity_id, v_site);
  perform erp.add_document_line(v_child2, v_item, 900, 1000, 'nine hundred, which is not what was approved');
  insert into erp.document_relation (tenant_id, from_document_id, to_document_id, relation_kind)
  values (r.tenant_id, v_child2, v_po2, 'converts');

  v_ctx := erp.document_transition_context(v_child2, 'submit');
  v_own := erp.request_document_approval_or_inherit(v_child2, v_ctx, r.entity_id, v_site);

  select ar.status::text into v_status
    from erp.approval_request ar where ar.tenant_id = r.tenant_id and ar.id = v_own;

  v_cases := v_cases + 1;
  case_name := 'but one that is not the commitment its parent was approved for is asked for on its own';
  passed := v_status = 'pending';
  detail := format('the child asked for itself: %s', v_status);
  return next;

  -- ── 7. And both doors ask through it ──────────────────────────────────────
  v_td := pg_get_functiondef('erp.transition_document(uuid, text, text)'::regprocedure);
  v_ee := pg_get_functiondef(
    'erp.execute_effects(text, uuid, jsonb, jsonb, uuid, uuid, text, text, text)'::regprocedure);

  v_cases := v_cases + 1;
  case_name := 'and both places that ask for a document approval ask through it';
  passed := position('request_document_approval_or_inherit' in v_td) > 0
        and position('request_document_approval_or_inherit' in v_ee) > 0
        and position('erp.request_approval(''document'', p_document_id' in v_td) = 0
        and position('erp.request_approval(''document'', p_object_id' in v_ee) = 0;
  detail := 'the submit arm and the require_approval effect, neither asking erp.request_approval directly any more';
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_fixture := left(sqlerrm, 300);
    end if;
  end;

  -- ── 8. Undone ─────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := not exists (select 1 from erp.tenant where code = 'zz-inh-' || v_hex)
        and v_fixture is null;
  detail := coalesce('the fixture stopped early: ' || v_fixture,
                     'the organisation rolled back with its orders and its approvals');
  return next;

  if v_cases <> 8 then
    raise exception 'CLOVEERP_SUITE_SHRANK: inherited_approval_suite ran % cases, expected 8 — %',
      v_cases, coalesce(v_fixture, 'no case was skipped');
  end if;
end;
$$;

comment on function erp_test.inherited_approval_suite() is
  'An approval that still holds is not asked for again: the document''s own '
  'where nothing material moved, or the one on the document it was raised '
  'from — and it is asked for the moment either stops being true.';

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

  if v_total <> 8 then
    raise exception 'CLOVEERP_INHERITED_APPROVAL_SUITE_SHRANK: % case(s), expected 8', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;

  if v_failed > 0 then
    raise exception 'CLOVEERP_INHERITED_APPROVAL_SUITE_FAILED: %/% case(s) failed%',
      v_failed, v_total, E'\n  ' || v_detail
      using hint = 'An approval carried where it should have been asked for is the worse half of this suite. Read the case that failed.';
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
