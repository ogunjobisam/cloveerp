set lock_timeout = '30s';

-- =============================================================================
-- 20261006110000  An approved order goes back to draft to be changed
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-07, J-54).
-- A purchase order converted from an approved requisition is born approved
-- with it. A buyer who then found a line missing added it on the approved
-- order, and Issue to supplier was drawn as if nothing were wrong; pressed,
-- it was refused with CLOVEERP_CARRIED_ORDER_CHANGED, and nothing could take
-- the line off again or ask anybody to approve the order as it now stood.
-- Since 20261006100000 a line changes only on a draft, so the line can no
-- longer be added; but an approved order then had no way to be put right at
-- all, short of an approver cancelling it.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. Procurement lifecycle version 5: a purchase order gains 'Back to
--      draft' (return_to_draft, approved -> draft), under procurement.order.
--      The buyer is who finds the mistake, and the move only ever takes an
--      approval away: the order must be submitted and approved again before
--      it is issued, so segregation of duties is untouched.
--   B. The approval an order carried from its requisition is withdrawn as it
--      goes back to draft, by an event (document.approval_revoked), never
--      silently kept. erp.carried_approval() reads what an order still
--      carries: the latest document.approval_carried, unless a withdrawal
--      came after it. Submitting the order asks for its own approval, as
--      every order does (erp.request_document_approval_or_inherit asks every
--      time), and Issue reads erp.carried_approval(), so an order approved on
--      its own after going back is issued on its own approval.
--   C. erp.transition_refusal() learns the refusal Issue meets on a carried
--      order changed since it was carried, so the menu holds Issue to
--      supplier with its reason instead of drawing it to be refused on press
--      (J-54). Today that is reachable only on an order changed before lines
--      froze (20261006100000). The refusal is restated with its new next
--      step, and the screen says why it is held.
--   D. erp_test.back_to_draft_suite.
--
-- Documents already in flight stay on the version they started on
-- (erp.perform_transition reads the version the document is pinned to): an
-- order approved before this reaches an organisation offers no Back to draft,
-- and its refusal says what it always said. The demonstration takes version
-- 5 through erp.demonstration_catch_up(), which upgrades the procurement
-- lifecycle when an upgrade is planned; a customer's organisation takes it
-- through Upgrade.
--
-- Production: no row is changed. The lifecycle payload, its upgrade row, a
-- driver register row, an event type, the refusal's words and one screen
-- string are written; no document moves.
--
-- Proof: erp_test.back_to_draft_suite; erp_test.procurement_policy_suite
-- re-pinned to version 5.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. Back to draft: procurement lifecycle version 5
-- ═════════════════════════════════════════════════════════════════════════════

do $lifecycle$
declare
  v_sig  constant text := 'erp.procurement_lifecycle_items(text,bigint,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$            jsonb_build_object('code','cancel_sent','name','Cancel','from','sent','to','cancelled','required_permission','procurement.approve')))),$o$;
  v_new  constant text := $n$            jsonb_build_object('code','cancel_sent','name','Cancel','from','sent','to','cancelled','required_permission','procurement.approve'),
            -- An approved order taken back to draft to be put right
            -- (20261006110000). The approval it held, its own or its
            -- requisition's, is withdrawn, and it is submitted for its own.
            jsonb_build_object('code','return_to_draft','name','Back to draft','from','approved','to','draft','required_permission','procurement.order')))),$n$;
begin
  if strpos(v_src, '20261006110000') > 0 then
    raise notice '% already takes an approved order back to draft; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'e79b152ff417f0f10c104b49295a85cd' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006110000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$lifecycle$;

update erp_ref.module_installer
   set current_version = 5,
       description = description
         || ' Version 5 (20261006110000): an approved order can be taken back to draft to be changed.'
 where install_code = 'procurement-lifecycle' and current_version = 4;

insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
select 'procurement-lifecycle', 5, x.value ->> 'kind', x.value ->> 'key', (x.value -> 'payload') - 'entity', 110
  from jsonb_array_elements(erp.procurement_lifecycle_items(null, 1000000, 'administrator')) x
 where (x.value ->> 'kind', x.value ->> 'key') = ('state_machine', 'purchase_order')
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

do $register$
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'procurement-lifecycle') is distinct from 5 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the procurement lifecycle installer is not at version 5';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       where ui.install_code = 'procurement-lifecycle' and ui.to_version = 5
         and ui.payload -> 'transitions' @> '[{"code": "return_to_draft"}]'::jsonb) <> 1 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 5 of procurement lifecycle is not the purchase order with return_to_draft';
  end if;
end
$register$;

-- A person's move, from the document page. Edited, not rewritten: one anchor
-- over the body 20261004990000 left.

do $drivers$
declare
  v_sig  constant text := 'erp.transition_driver_register()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$      ('purchase_order',     'cancel_approved',        'screen', ''),$o$;
  v_new  constant text := $n$      ('purchase_order',     'cancel_approved',        'screen', ''),
      -- Taken back to draft to be put right, its approval withdrawn
      -- (20261006110000).
      ('purchase_order',     'return_to_draft',        'screen', ''),$n$;
begin
  if strpos(v_src, 'return_to_draft') > 0 then
    raise notice '% already names return_to_draft; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'd1f0947c3131db9795459441f1230012' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006110000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$drivers$;

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The carried approval is withdrawn as the order goes back
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values
  ('document.approval_revoked', 1, 'document', 'procurement', 'event.document.approval_revoked',
   'A purchase order was taken back to draft, and the approval it held, its own or its requisition''s, was withdrawn.',
   '{"type":"object","required":["carried"],"properties":{"carried":{"type":"boolean"},"reason":{"type":"string"},"approval_request_id":{"type":"string"}}}'::jsonb, true)
on conflict do nothing;

do $event$
begin
  if (select count(*) from erp_ref.event_type et
       where et.code = 'document.approval_revoked'
         and et.is_current and et.version = 1 and et.name_key = 'event.' || et.code) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: document.approval_revoked is declared already, and not as 20261006110000 declares it';
  end if;
end
$event$;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.document.approval_revoked', 'en', 'Order taken back to draft', 'procurement',
   'Event raised when a purchase order is taken back to draft and the approval it held is withdrawn (20261006110000).'),
  ('event.document.approval_revoked', 'de', 'Bestellung in den Entwurf zurückgenommen', 'procurement',
   'Ereignis, wenn eine Bestellung in den Entwurf zurückgenommen und ihre Genehmigung zurückgezogen wird.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

create or replace function erp.carried_approval(p_order_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- What an order still carries of its requisition's approval
  -- (20261006110000): the payload of its latest document.approval_carried,
  -- and nothing once the order has been taken back to draft after it
  -- (document.approval_revoked). Read by Issue in erp.transition_document()
  -- and by the menu in erp.transition_refusal(), so the two cannot disagree.
  select c.payload
    from erp.event c
   where c.tenant_id = erp.current_tenant_id()
     and c.aggregate_type = 'document' and c.aggregate_id = p_order_id
     and c.event_type = 'document.approval_carried'
     and not exists (select 1 from erp.event w
                      where w.tenant_id = c.tenant_id
                        and w.aggregate_type = 'document' and w.aggregate_id = c.aggregate_id
                        and w.event_type = 'document.approval_revoked'
                        and w.global_seq > c.global_seq)
   order by c.global_seq desc
   limit 1
$$;

revoke all on function erp.carried_approval(uuid) from public, anon;

comment on function erp.carried_approval(uuid) is
  'The approval a purchase order still carries from its requisition: the latest document.approval_carried payload, '
  'or null once the order has been taken back to draft after it (20261006110000).';

-- Issue reads what the order still carries, and Back to draft withdraws it.
-- Edited, not rewritten: two anchors over the body 20261006061000 left.

do $transition$
declare
  v_sig   constant text := 'erp.transition_document(uuid,text,text)';
  v_src   text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def   text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_a_old constant text := $a$  -- D5 (a): an order approved with its requisition is issued as it was
  -- converted, or not at all.
  if dt.base_type_code = 'purchase_order' and p_transition_code = 'send' then
    select ev.payload into v_carry
      from erp.event ev
     where ev.tenant_id = v_tenant and ev.aggregate_type = 'document'
       and ev.aggregate_id = p_document_id
       and ev.event_type = 'document.approval_carried'
     order by ev.global_seq desc
     limit 1;$a$;
  v_a_new constant text := $a$  -- An approved order taken back to draft gives up the approval it held,
  -- its requisition's above all (20261006110000): withdrawn by an event,
  -- never silently kept, and asked for again when it is submitted.
  if dt.base_type_code = 'purchase_order' and p_transition_code = 'return_to_draft' then
    v_carry := erp.carried_approval(p_document_id);
    perform erp.append_event('document.approval_revoked', 'document', p_document_id,
      jsonb_strip_nulls(jsonb_build_object(
        'carried', v_carry is not null,
        'approval_request_id', v_carry ->> 'approval_request_id',
        'reason', nullif(btrim(coalesce(p_reason, '')), ''))),
      d.entity_id, d.site_id);
    v_carry := null;
  end if;

  -- D5 (a): an order approved with its requisition is issued as it was
  -- converted, or not at all. What it still carries is
  -- erp.carried_approval()'s to say (20261006110000): nothing, once it has
  -- been taken back to draft and approved on its own.
  if dt.base_type_code = 'purchase_order' and p_transition_code = 'send' then
    v_carry := erp.carried_approval(p_document_id);$a$;
  v_b_old constant text := $b$        using errcode = '23514',
              hint = 'Put the order back as it was converted, or have an approver cancel it and raise it again for its own approval.';$b$;
  v_b_new constant text := $b$        using errcode = '23514',
              -- Where its version has the way back (20261006110000).
              hint = case when erp.document_declares_move(p_document_id, 'return_to_draft')
                          then 'Take it back to draft, put it right there and submit it for its own approval.'
                          else 'Put the order back as it was converted, or have an approver cancel it and raise it again for its own approval.'
                     end;$b$;
begin
  if strpos(v_src, '20261006110000') > 0 then
    raise notice '% already reads the carried approval; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '57b718a5224b93fb878050a0c4220366' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006110000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_a_old, ''))) / length(v_a_old) <> 1
     or (length(v_def) - length(replace(v_def, v_b_old, ''))) / length(v_b_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchors found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_a_old, v_a_new), v_b_old, v_b_new);
end
$transition$;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. The menu holds Issue with the refusal the door would give
-- ═════════════════════════════════════════════════════════════════════════════

do $refusal$
declare
  v_sig  constant text := 'erp.transition_refusal(uuid,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  -- Reject, of a transfer order or stock adjustment waiting for approval,
  -- is the approvers' and the asker's (20260928500000).$o$;
  v_new  constant text := $n$  -- Issue, of an order approved with its requisition and changed since
  -- (20261006110000): the same two reads erp.transition_document() makes,
  -- so Issue to supplier is held with its reason rather than refused on
  -- press (J-54).
  if p_transition_code = 'send' and v_tenant is not null
     and exists (select 1 from erp.document d
                   join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
                  where d.tenant_id = v_tenant and d.id = p_document_id
                    and dt.base_type_code = 'purchase_order')
     and erp.carried_order_change(p_document_id, erp.carried_approval(p_document_id)) is not null then
    return 'CLOVEERP_CARRIED_ORDER_CHANGED';
  end if;

  -- Reject, of a transfer order or stock adjustment waiting for approval,
  -- is the approvers' and the asker's (20260928500000).$n$;
begin
  if strpos(v_src, '20261006110000') > 0 then
    raise notice '% already holds a changed carried order at Issue; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '245d41796d8b385032f9184715eed031' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006110000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$refusal$;

select erp.register_refusal('CLOVEERP_CARRIED_ORDER_CHANGED',
  'Issuing a purchase order approved with its requisition after its lines or its value were changed.',
  'Nobody but the requisition''s approver looked at an order approved with it. Changed and then issued, it would commit the organisation to something nobody approved.',
  'Take it back to draft, put it right there and submit it for its own approval. An order approved before it could go back is cancelled by an approver and raised again.');

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Said on a purchase order instead of Issue to supplier, when it was changed since it was approved with its requisition (20261006110000).'
  from (values
    ('Changed since it was approved with its requisition. Take it back to draft and submit it for its own approval.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- D. The proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.back_to_draft_suite()
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
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_item2 uuid; v_sup uuid;
  v_r      uuid; v_po uuid; v_pl uuid; v_po2 uuid; v_pl2 uuid; v_po3 uuid;
  v_role   uuid; v_other uuid; v_other_tok text;
  v_x      text; v_x2 text; v_hint text; v_refused text;
  v_n      integer;
  v_ok     boolean;
begin
  begin
    -- ── The fixture ───────────────────────────────────────────────────────────
    v_step := 'an organisation that buys, not yet live';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzbtd-' || v_tag, 'Back To Draft Suite',
      'admin@zzbtd-' || v_tag || '.test', 'Draft Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzbtd-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    res := erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_entity := (res ->> 'entity_id')::uuid;
    v_site := (res ->> 'site_id')::uuid;
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base and u.uom_class = 'quantity' and u.status = 'active'
     order by u.code limit 1;
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZBTDSUP', 'Back To Draft Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZBTDWID', 'Back To Draft Widget', v_uom, 'active') returning id into v_item;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZBTDBOLT', 'Back To Draft Bolt', v_uom, 'active') returning id into v_item2;

    -- A requisition naming its supplier, approved, and converted: the order
    -- is born approved with it.
    v_step := 'an order approved with its requisition';
    v_r := erp.open_document('requisition', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_r, v_item, 10, 1000, 'ten widgets');
    perform erp.transition_document(v_r, 'submit', null);
    perform erp.approve_my_document_tasks(v_r, 'the back to draft suite');
    if erp.object_current_state('document', v_r) = 'submitted' then
      perform erp.transition_document(v_r, 'approve', null);
    end if;
    res := erp.convert_document(v_r, null, null, null);
    v_po := (res ->> 'document_id')::uuid;
    select l.id into v_pl from erp.document_line l where l.tenant_id = rb.tenant_id and l.document_id = v_po;

    -- ── 1. A line on the approved order is refused, and says the way back ────
    v_step := 'a line on the approved order';
    v_x := null; v_hint := null;
    begin
      perform erp.add_document_line(v_po, v_item2, 2, 500, 'two bolts');
      v_x := 'added';
    exception when others then
      v_x := left(sqlerrm, 200);
      get stacked diagnostics v_hint = pg_exception_hint;
    end;
    v_cases := v_cases + 1;
    case_name := 'a line on an order approved with its requisition is refused, and the refusal says to take it back to draft';
    passed := v_state is null
          and erp.object_current_state('document', v_po) = 'approved'
          and erp.carried_approval(v_po) is not null
          and v_x like 'CLOVEERP_LINES_CHANGED_ONLY_AS_A_DRAFT%'
          and v_hint = 'Take it back to draft, change it there and submit it again.';
    detail := coalesce(v_state, format('order %s; carried %s; add: %s; hint: %s',
                erp.object_current_state('document', v_po), erp.carried_approval(v_po) is not null, v_x, v_hint));
    return next;

    -- ── 2. Back to draft ──────────────────────────────────────────────────────
    v_step := 'taking the order back to draft';
    v_x := erp.transition_document(v_po, 'return_to_draft', 'A line was missing');
    v_cases := v_cases + 1;
    case_name := 'back to draft, the order no longer carries its requisition''s approval, and says it was withdrawn';
    passed := v_state is null and v_x = 'draft'
          and erp.carried_approval(v_po) is null
          and exists (select 1 from erp.event ev
                       where ev.tenant_id = rb.tenant_id and ev.aggregate_id = v_po
                         and ev.event_type = 'document.approval_revoked'
                         and (ev.payload ->> 'carried')::boolean
                         and ev.payload ->> 'reason' = 'A line was missing')
          and (public.erp_document(v_po) -> 'document' ->> 'lines_open')::boolean;
    detail := coalesce(v_state, format('moved to %s; carried %s; lines open %s', v_x,
                erp.carried_approval(v_po) is not null, public.erp_document(v_po) -> 'document' ->> 'lines_open'));
    return next;

    -- ── 3. Its lines change there ─────────────────────────────────────────────
    v_step := 'changing the draft''s lines';
    perform public.erp_change_document_line(v_pl, 8, null, null);
    v_pl2 := erp.add_document_line(v_po, v_item2, 2, 500, 'two bolts');
    v_cases := v_cases + 1;
    case_name := 'at draft its lines change: one lowered and one added';
    passed := v_state is null and v_pl2 is not null
          and erp.document_value_minor(v_po) = 9000;
    detail := coalesce(v_state, format('value %s', erp.document_value_minor(v_po)));
    return next;

    -- ── 4. Submitted, it asks for its own approval ────────────────────────────
    v_step := 'submitting it again';
    v_x := erp.transition_document(v_po, 'submit', null);
    select count(*) into v_n from erp.approval_request q
     where q.tenant_id = rb.tenant_id and q.object_type = 'document' and q.object_id = v_po
       and q.status = 'pending';
    v_cases := v_cases + 1;
    case_name := 'submitted, it waits for its own approval: the requisition''s is not given to it again';
    passed := v_state is null and v_x = 'pending_approval' and v_n = 1
          and erp.carried_approval(v_po) is null;
    detail := coalesce(v_state, format('submit moved it to %s; %s pending request(s)', v_x, v_n));
    return next;

    -- ── 5. Approved on its own, it is issued ──────────────────────────────────
    v_step := 'approving it and issuing it';
    v_x := erp_test.approve_document(v_po, null);
    v_x2 := null;
    begin
      v_x2 := erp.transition_document(v_po, 'send', null);
    exception when others then v_x2 := left(sqlerrm, 200);
    end;
    v_cases := v_cases + 1;
    case_name := 'approved on its own, it is issued: the approval it carried no longer holds it back';
    passed := v_state is null and v_x = 'approved' and v_x2 = 'sent';
    detail := coalesce(v_state, format('approval %s; issue %s', v_x, v_x2));
    return next;

    -- ── 6. An order changed past its carried approval before lines froze ──────
    v_step := 'an order changed before lines froze';
    v_r := erp.open_document('requisition', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_r, v_item, 10, 1000, 'ten widgets');
    perform erp.transition_document(v_r, 'submit', null);
    perform erp.approve_my_document_tasks(v_r, 'the back to draft suite');
    if erp.object_current_state('document', v_r) = 'submitted' then
      perform erp.transition_document(v_r, 'approve', null);
    end if;
    res := erp.convert_document(v_r, null, null, null);
    v_po2 := (res ->> 'document_id')::uuid;
    -- As a line added before 20261006100000 left it.
    insert into erp.document_line (tenant_id, document_id, line_no, item_id, description,
                                   quantity, uom_id, unit_price_minor, net_minor, currency)
    select dl.tenant_id, dl.document_id, dl.line_no + 10, v_item2, 'two bolts',
           2, dl.uom_id, 500, 1000, dl.currency
      from erp.document_line dl
     where dl.tenant_id = rb.tenant_id and dl.document_id = v_po2
     order by dl.line_no limit 1;
    select e ->> 'refused' into v_refused
      from jsonb_array_elements(public.erp_available_transitions(v_po2)) e
     where e ->> 'code' = 'send';
    v_x := null; v_hint := null;
    begin
      perform erp.transition_document(v_po2, 'send', null);
      v_x := 'issued';
    exception when others then
      v_x := left(sqlerrm, 200);
      get stacked diagnostics v_hint = pg_exception_hint;
    end;
    v_x2 := erp.transition_document(v_po2, 'return_to_draft', null);
    v_cases := v_cases + 1;
    case_name := 'an order changed past its carried approval is held at Issue with the refusal the door gives, and goes back to draft';
    passed := v_state is null
          and v_refused = 'CLOVEERP_CARRIED_ORDER_CHANGED'
          and v_x like 'CLOVEERP_CARRIED_ORDER_CHANGED%'
          and v_hint = 'Take it back to draft, put it right there and submit it for its own approval.'
          and v_x2 = 'draft'
          and not exists (select 1 from jsonb_array_elements(public.erp_available_transitions(v_po2)) e
                           where e ->> 'refused' = 'CLOVEERP_CARRIED_ORDER_CHANGED');
    detail := coalesce(v_state, format('menu refused %s; door %s (hint %s); back: %s',
                coalesce(v_refused, 'nothing'), v_x, coalesce(v_hint, 'none'), v_x2));
    return next;

    -- ── 7. Somebody who may approve, but not raise, orders ────────────────────
    v_step := 'an approver who raises no orders';
    v_r := erp.open_document('requisition', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_r, v_item, 3, 1000, 'three widgets');
    perform erp.transition_document(v_r, 'submit', null);
    perform erp.approve_my_document_tasks(v_r, 'the back to draft suite');
    if erp.object_current_state('document', v_r) = 'submitted' then
      perform erp.transition_document(v_r, 'approve', null);
    end if;
    res := erp.convert_document(v_r, null, null, null);
    v_po3 := (res ->> 'document_id')::uuid;
    insert into erp.role (tenant_id, code, name, status)
    values (rb.tenant_id, 'zz_btd_approver', 'Back to draft approver', 'active') returning id into v_role;
    insert into erp.role_permission (tenant_id, role_id, permission_code) values
      (rb.tenant_id, v_role, 'procurement.read'),
      (rb.tenant_id, v_role, 'procurement.approve');
    res := public.erp_invite_principal('approver@zzbtd-' || v_tag || '.test', 'Andy Approver');
    v_other := (res ->> 'app_user_id')::uuid;
    v_other_tok := res ->> 'token';
    perform erp.grant_role(v_other, 'zz_btd_approver', null, null, 'approves and raises nothing');
    insert into auth.users (id, email) values (a2, 'approver@zzbtd-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_other_tok);
    v_x := null;
    begin
      perform erp.transition_document(v_po3, 'return_to_draft', null);
      v_x := 'taken back';
    exception when others then v_x := left(sqlerrm, 200);
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'taking an order back to draft is the buyer''s: somebody who only approves is refused';
    passed := v_state is null
          and v_x like 'CLOVEERP_PERMISSION_DENIED: procurement.order%'
          and erp.object_current_state('document', v_po3) = 'approved'
          and erp.carried_approval(v_po3) is not null;
    detail := coalesce(v_state, format('%s; order %s', v_x, erp.object_current_state('document', v_po3)));
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
    raise exception 'CLOVEERP_BACK_TO_DRAFT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.back_to_draft_suite() from public, anon;

comment on function erp_test.back_to_draft_suite() is
  'An approved order goes back to draft to be changed (20261006110000): the carried approval withdrawn, the order '
  'asked for its own, Issue held with the door''s refusal on an order changed past its carry, and the move the buyer''s.';

create or replace function erp_test.assert_back_to_draft_suite()
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
    from erp_test.back_to_draft_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_BACK_TO_DRAFT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'An approved order could not be put right, or kept an approval nobody gave it. Read the case that failed.';
  end if;
  if v_total <> 7 then
    raise exception 'CLOVEERP_BACK_TO_DRAFT_SUITE_SHRANK: % case(s), expected 7', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('back to draft: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_back_to_draft_suite() from public, anon;

comment on function erp_test.assert_back_to_draft_suite() is
  'An approved order goes back to draft with its carried approval withdrawn, and Issue is held where the door refuses it (20261006110000).';

-- The procurement policy suite pinned a new install at version 4.

do $repin$
declare
  v_sig  constant text := 'erp_test.procurement_policy_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$      -- Version 4 since 20261004990000: a sent order can be cancelled.
      v_ver = 4
$o$;
  v_new  constant text := $n$      -- Version 5 since 20261006110000: an approved order goes back to draft.
      v_ver = 5
$n$;
begin
  if strpos(v_src, '20261006110000') > 0 then
    raise notice '% already re-pinned; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '7686628f3a8b51ed027a53970acea7d3' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006110000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$repin$;

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
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
