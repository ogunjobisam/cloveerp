set lock_timeout = '30s';

-- =============================================================================
-- 20260922380000  An order is approved with its requisition
-- -----------------------------------------------------------------------------
-- PR4, M2: node P1 of docs/spec/simplification-review.md, and PR4's decision 6.
-- Version 2 of the procurement lifecycle. Nothing here writes tenant data: an
-- organisation takes version 2 through Upgrade, a demonstration through its
-- catch-up, and a new organisation at install.
--
-- ── WHAT VERSION 2 CHANGES ───────────────────────────────────────────────────
--
-- A requisition asks for the value approval an order asks for today
-- (requisition_value, the same steps as purchase_order_value). An order
-- converted from an approved requisition, unchanged and to the supplier and
-- site the requisition named, is born approved: the conversion makes the new
-- move `inherit_approval` (draft → approved, "Approved with its requisition")
-- and nobody is asked twice. The conversion never issues it.
--
--   requisition.order              gains is_automatic (the conversion makes it)
--   purchase_order.sent            "Sent to supplier" → "Issued"
--   purchase_order.send            "Send to supplier" → "Issue to supplier"
--   purchase_order.inherit_approval  new, automatic, procurement.order
--   purchase_order.receive_partial gains is_automatic (the receipt makes it)
--   requisition document type      gains approval_chain requisition_value
--
-- No code is removed or renamed (PR4 decision 1). receive_all, receive_rest
-- and close stay a person's, with a reason, as M1 left them.
--
-- ── WHAT CARRIES AN APPROVAL, AND WHAT DOES NOT ──────────────────────────────
--
-- erp.conversion_keeps_approval() is the one test, read by the conversion and
-- again by the door. 20260922320000 called trusting erp.document_relation as
-- lineage the mistake. This trusts only relations this conversion wrote in
-- this transaction: the order was created now, has never moved, has never
-- been asked about, and erp.carrying_approval names its id. Only
-- erp.convert_document() writes a line-level `converts` from an order line to
-- a requisition line. Each order line must be its requisition line: same
-- item, unit, price, discount and words, no more than its quantity. Together
-- the orders may exceed the approved value by rounding only (D6). A
-- requisition written after it was asked about, even if put back, carries
-- nothing. A requisition approved by its own requester carries nothing in a
-- live organisation (D2, fail closed).
--
-- An order that does not carry stays a draft, as today (D1). A born-approved
-- order changed before it is issued is refused Issue until it is put back
-- (D5, CLOVEERP_CARRIED_ORDER_CHANGED).
--
-- The whole design, as every door's, rests on the erp schema not being
-- exposed through PostgREST: `authenticated` holds DML on every table the
-- test reads, because the doors run as the caller. D7 checks that at deploy.
--
-- ── PR4 DECISION 6: A MOVE THE SYSTEM DERIVES TAKES ITS AUTHORITY FROM THE FACT
--
-- Answers 20260922370000's note on a derived close made by somebody who may
-- not close. erp.close_order_when_settled() and a requisition's `order` made
-- by erp.convert_document() name themselves in erp.deriving_move, and
-- erp.perform_transition() answers erp.authorise()'s permission refusal, and
-- only that, with erp.derived_move_fact(), read again under the state lock.
-- The person stays the actor; the log's guard_data says `derived`. An
-- organisation's own permission on those two moves now governs only the move
-- made by hand (D8). A close by hand keeps its permission and M1's guard.
--
-- Because the fact now closes orders for anybody, the bill it reads is held
-- to what it says: erp.invoice_against() invoices only onto an unposted bill
-- from the order's own supplier, and erp.amend_document_line() carries a bill
-- line's new quantity into its relation and matches again.
--
-- ── WHAT LATER VERSIONS MUST DO ──────────────────────────────────────────────
--
-- erp.undriven_transition_report() excuses a code only the installer's
-- CURRENT upgrade payload declares. Every later procurement-lifecycle version
-- must restate the purchase order machine with inherit_approval, or the
-- replay from an empty cluster fails the next migration's final assert.
--
-- ── WHAT CHANGES FOR DOCUMENTS IN FLIGHT ─────────────────────────────────────
--
-- None. Every document stays on the version it started on. An approval given
-- before this carries nothing, because its context has no line fingerprint.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. Version 2 of the configuration, from one helper
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.procurement_lifecycle_items(
  p_entity_code text, p_threshold_minor bigint, p_approver_role text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- Version 2 of the procurement lifecycle (20260922380000), read by
  -- erp.configure_procurement() for a new install and by the upgrade register
  -- for an organisation on version 1, so the two cannot disagree.
  select jsonb_build_array(
      jsonb_build_object('kind','state_machine','key','requisition','payload',
        jsonb_build_object(
          'code','requisition','object_type','document','name','Requisition',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','submitted','name','Submitted','sort_order',20),
            jsonb_build_object('code','approved','name','Approved','sort_order',30),
            jsonb_build_object('code','ordered','name','Ordered','is_terminal',true,'is_committed',true,'sort_order',40),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','submit','name','Submit','from','draft','to','submitted','required_permission','procurement.requisition','effects',jsonb_build_array(jsonb_build_object('kind','require_approval'))),
            jsonb_build_object('code','approve','name','Approve','from','submitted','to','approved','required_permission','procurement.approve'),
            jsonb_build_object('code','reject','name','Reject','from','submitted','to','draft','required_permission','procurement.approve'),
            jsonb_build_object('code','order','name','Convert to order','from','approved','to','ordered','required_permission','procurement.order','is_automatic',true),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.requisition'),
            jsonb_build_object('code','cancel_submitted','name','Cancel','from','submitted','to','cancelled','required_permission','procurement.approve')))),

      jsonb_build_object('kind','state_machine','key','purchase_order','payload',
        jsonb_build_object(
          'code','purchase_order','object_type','document','name','Purchase order',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','pending_approval','name','Pending approval','sort_order',20),
            jsonb_build_object('code','approved','name','Approved','sort_order',30),
            jsonb_build_object('code','sent','name','Issued','is_committed',true,'sort_order',40),
            jsonb_build_object('code','partially_received','name','Partially received','is_committed',true,'sort_order',50),
            jsonb_build_object('code','received','name','Received','is_committed',true,'sort_order',60),
            jsonb_build_object('code','closed','name','Closed','is_terminal',true,'is_committed',true,'sort_order',70),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','submit','name','Submit for approval','from','draft','to','pending_approval','required_permission','procurement.order','effects',jsonb_build_array(jsonb_build_object('kind','require_approval'))),
            jsonb_build_object('code','approve','name','Approve','from','pending_approval','to','approved','required_permission','procurement.approve'),
            jsonb_build_object('code','reject','name','Reject','from','pending_approval','to','draft','required_permission','procurement.approve'),
            jsonb_build_object('code','inherit_approval','name','Approved with its requisition','from','draft','to','approved','required_permission','procurement.order','is_automatic',true),
            jsonb_build_object('code','send','name','Issue to supplier','from','approved','to','sent','required_permission','procurement.order'),
            jsonb_build_object('code','receive_partial','name','Receive part','from','sent','to','partially_received','required_permission','procurement.receive','is_automatic',true),
            jsonb_build_object('code','receive_rest','name','Receive remainder','from','partially_received','to','received','required_permission','procurement.receive'),
            jsonb_build_object('code','receive_all','name','Receive in full','from','sent','to','received','required_permission','procurement.receive'),
            jsonb_build_object('code','close','name','Close','from','received','to','closed','required_permission','procurement.order'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.order'),
            jsonb_build_object('code','cancel_approved','name','Cancel','from','approved','to','cancelled','required_permission','procurement.approve')))),

      jsonb_build_object('kind','state_machine','key','goods_receipt','payload',
        jsonb_build_object(
          'code','goods_receipt','object_type','document','name','Goods receipt',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','posted','name','Posted','is_terminal',true,'is_committed',true,'sort_order',20),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','post','name','Post','from','draft','to','posted','required_permission','procurement.receive'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.receive')))),

      jsonb_build_object('kind','approval_chain','key','purchase_order_value','payload',
        jsonb_build_object(
          'code','purchase_order_value','name','Purchase order value approval',
          'object_type','document',
          'applies_when', jsonb_build_object('==', jsonb_build_array(
            jsonb_build_object('var','document_type'),'purchase_order')),
          'value_field','total_minor','priority',100,
          'material_fields', jsonb_build_array('total_minor','party_id'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','buyer_manager','name','Buying manager',
              'approver_kind','role','role',p_approver_role,'min_approvals',1),
            jsonb_build_object('seq',2,'code','finance','name','Finance',
              'approver_kind','role','role',p_approver_role,'min_approvals',1,
              'condition', jsonb_build_object('>', jsonb_build_array(
                jsonb_build_object('var','total_minor'), p_threshold_minor)))))),

      -- The requisition is asked what the order used to be asked, so the order
      -- raised from it need not be asked again.
      jsonb_build_object('kind','approval_chain','key','requisition_value','payload',
        jsonb_build_object(
          'code','requisition_value','name','Requisition value approval',
          'object_type','document',
          'applies_when', jsonb_build_object('==', jsonb_build_array(
            jsonb_build_object('var','document_type'),'requisition')),
          'value_field','total_minor','priority',100,
          'material_fields', jsonb_build_array('total_minor','party_id'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','buyer_manager','name','Buying manager',
              'approver_kind','role','role',p_approver_role,'min_approvals',1),
            jsonb_build_object('seq',2,'code','finance','name','Finance',
              'approver_kind','role','role',p_approver_role,'min_approvals',1,
              'condition', jsonb_build_object('>', jsonb_build_array(
                jsonb_build_object('var','total_minor'), p_threshold_minor)))))),

      -- The spine, in the change set and after the lifecycles it names.
      -- erp.promote_change_set() applies items in seq order and
      -- erp.add_change_set_item() assigns seq in the order they appear here,
      -- so a document type is written only once its state machine, its chain
      -- and its sequence exist.
      jsonb_build_object('kind','numbering_rule','key','requisition','payload',
        jsonb_build_object('code','requisition','entity',p_entity_code,
          'prefix','REQ-','pad_to',6,'reset_period','yearly','next_value',1)),
      jsonb_build_object('kind','numbering_rule','key','purchase_order','payload',
        jsonb_build_object('code','purchase_order','entity',p_entity_code,
          'prefix','PO-','pad_to',6,'reset_period','yearly','next_value',1)),
      jsonb_build_object('kind','numbering_rule','key','goods_receipt','payload',
        jsonb_build_object('code','goods_receipt','entity',p_entity_code,
          'prefix','GRN-','pad_to',6,'reset_period','yearly','next_value',1)),

      -- A requisition asks; it neither moves stock nor reaches a ledger. The
      -- nulls are the honest answer rather than an omission:
      -- erp.assert_no_dead_configuration() fails the build if a base type
      -- disagrees with them in either direction.
      jsonb_build_object('kind','document_type','key','requisition','payload',
        jsonb_build_object('code','requisition','base_type','requisition',
          'name','Requisition','entity',p_entity_code,
          'numbering_rule','requisition','state_machine','requisition',
          'approval_chain','requisition_value')),
      -- An order commits. Nothing has moved and nothing is owed yet, so the
      -- entry belongs in the parallel commitment ledger, not the statutory one.
      jsonb_build_object('kind','document_type','key','purchase_order','payload',
        jsonb_build_object('code','purchase_order','base_type','purchase_order',
          'name','Purchase order','entity',p_entity_code,
          'numbering_rule','purchase_order','state_machine','purchase_order',
          'approval_chain','purchase_order_value',
          'posting_rule','purchase_commitment')),
      -- A receipt is the first point at which both ledgers have something to say.
      jsonb_build_object('kind','document_type','key','goods_receipt','payload',
        jsonb_build_object('code','goods_receipt','base_type','receipt',
          'name','Goods receipt','entity',p_entity_code,
          'numbering_rule','goods_receipt','state_machine','goods_receipt',
          'stock_movement_type','goods_receipt',
          'posting_rule','goods_receipt')))
$$;

revoke execute on function erp.procurement_lifecycle_items(text, bigint, text) from public, anon, authenticated;

comment on function erp.procurement_lifecycle_items(text, bigint, text) is
  'The procurement lifecycle''s configuration items at the installer''s current '
  'version (2, 20260922380000): what erp.configure_procurement() installs and '
  'what the upgrade register offers an organisation on version 1.';

-- The installer on the helper: same signature, same checks. Its items were
-- written out inline; they are now the helper's, so a new install and an
-- upgrade are the same configuration.
do $configure$
declare
  v_sig constant text := 'erp.configure_procurement(bigint,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_open  constant text := $o$    jsonb_build_array(
$o$;
  v_close constant text := $o$  return v_cs;
$o$;
  v_from integer := position(v_open in v_def);
  v_to   integer := position(v_close in v_def);
begin
  if (length(v_def) - length(replace(v_def, v_open, ''))) / length(v_open) <> 1
     or (length(v_def) - length(replace(v_def, v_close, ''))) / length(v_close) <> 1
     or v_from = 0 or v_to <= v_from then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % does not list its items where this migration expects', v_sig;
  end if;
  execute substr(v_def, 1, v_from - 1)
       || '    erp.procurement_lifecycle_items(v_entity_code, p_approval_threshold_minor, p_approver_role));' || E'\n\n'
       || substr(v_def, v_to);
  if position('erp.procurement_lifecycle_items(' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % was not rewritten onto the helper', v_sig;
  end if;
end
$configure$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The upgrade register: version 2 for an organisation on version 1
-- ─────────────────────────────────────────────────────────────────────────────

update erp_ref.module_installer
   set current_version = 2,
       description = description
         || ' Version 2 (20260922380000): a requisition carries the value approval, '
         || 'and an order converted from it unchanged is approved with it.'
 where install_code = 'procurement-lifecycle' and current_version = 1;

-- The four objects version 2 changes, each as the helper writes it at the
-- defaults, less its entity: the approver and threshold are restated at the
-- defaults, as approved (PR4 plan, P1).
insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
select 'procurement-lifecycle', 2, x.value ->> 'kind', x.value ->> 'key',
       (x.value -> 'payload') - 'entity',
       case (x.value ->> 'kind') || '.' || (x.value ->> 'key')
         when 'state_machine.requisition'        then 100
         when 'state_machine.purchase_order'     then 110
         when 'approval_chain.requisition_value' then 120
         when 'document_type.requisition'        then 130 end
  from jsonb_array_elements(erp.procurement_lifecycle_items(null, 1000000, 'administrator')) x
 where (x.value ->> 'kind', x.value ->> 'key') in (
         ('state_machine','requisition'), ('state_machine','purchase_order'),
         ('approval_chain','requisition_value'), ('document_type','requisition'))
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

do $register$
declare
  v_n integer;
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'procurement-lifecycle') is distinct from 2 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the procurement lifecycle installer is not at version 2';
  end if;
  select count(*) into v_n
    from erp_ref.module_upgrade_item ui
    join jsonb_array_elements(erp.procurement_lifecycle_items(null, 1000000, 'administrator')) x
      on x.value ->> 'kind' = ui.object_kind and x.value ->> 'key' = ui.object_key
     and (x.value -> 'payload') - 'entity' = ui.payload
   where ui.install_code = 'procurement-lifecycle' and ui.to_version = 2;
  if v_n <> 4 or (select count(*) from erp_ref.module_upgrade_item
                   where install_code = 'procurement-lifecycle' and to_version = 2) <> 4 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 2 of the procurement lifecycle has % matching item(s), expected 4', v_n;
  end if;
end
$register$;

-- An upgrade item that replaces something the organisation holds says so.
-- It read "configuration the organisation lacks" for a lifecycle it had.
do $plan$
declare
  v_sig constant text := 'erp.plan_module_upgrade(text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$           case when ui.object_kind = 'posting_rule' then 'a posting rule the organisation lacks'
                else 'configuration the organisation lacks' end,
$o$;
  v_new constant text := $n$           case when ui.object_kind = 'posting_rule' then 'a posting rule the organisation lacks'
                -- A newer version of something it holds (20260922380000).
                when exists (select 1 from erp.configuration_manifest(array[ui.object_kind]) m
                              where m.object_key = ui.object_key)
                  then 'a newer version of configuration the organisation holds, which replaces it'
                else 'configuration the organisation lacks' end,
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % effect anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$plan$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. The demonstration
--
-- Each demonstration the deploy visits is upgraded in its own catch-up, in a
-- block of its own: a refusal is a note, and it trades on version 1. The
-- seeder asks the requisition of the supplier the conversion orders from
-- (D3), decides the approval tasks it holds, and presses submit and approve
-- on an order only while it is still a draft.
-- ─────────────────────────────────────────────────────────────────────────────

do $catch_up$
declare
  v_sig constant text := 'erp.demonstration_catch_up()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  -- ── Trading, up to the day this runs or the time this statement has ────────
$o$;
  v_new constant text := $n$  -- ── The procurement lifecycle's newer version (20260922380000) ─────────────
  --
  -- Before the no-history exit below, so every demonstration the deploy
  -- visits is tried, whether or not it trades today. A demonstration is never
  -- live, so the upgrade promotes at once. The two tests are nested because
  -- erp.plan_module_upgrade() raises for an organisation with no
  -- installation, and SQL does not fix the order an `and` is evaluated in.
  begin
    if exists (select 1 from erp.module_installation i
                where i.tenant_id = v_tenant and i.install_code = 'procurement-lifecycle') then
      if exists (select 1 from erp.plan_module_upgrade('procurement-lifecycle')) then
        perform erp.upgrade_module_configuration('procurement-lifecycle');
        v_notes := v_notes || to_jsonb(format(
          'The procurement lifecycle was upgraded to version %s.',
          (select mi.current_version from erp_ref.module_installer mi
            where mi.install_code = 'procurement-lifecycle')));
      end if;
    end if;
  exception when others then
    v_notes := v_notes || to_jsonb(format(
      'The procurement lifecycle was not upgraded, so it trades on the version it has: %s', sqlerrm));
  end;

  -- ── Trading, up to the day this runs or the time this statement has ────────
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % trading anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$catch_up$;

do $seed$
declare
  v_sig constant text := 'erp.seed_demo_history(date,date,numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  -- 1. The order raised from the requisition: asked for only while a draft.
  a1 constant text := $o$      perform erp.transition_document(v_conv, 'submit', 'demonstration');
      perform erp.approve_my_document_tasks(v_conv, 'demonstration');
      perform erp.transition_document(v_conv, 'approve', 'demonstration');
      perform erp.transition_document(v_conv, 'send', 'demonstration');
$o$;
  b1 constant text := $n$      -- Approved with its requisition when that named its supplier
      -- (20260922380000); otherwise asked for, as every other order here is.
      if erp.object_current_state('document', v_conv) = 'draft' then
        perform erp.transition_document(v_conv, 'submit', 'demonstration');
        perform erp.approve_my_document_tasks(v_conv, 'demonstration');
        perform erp.transition_document(v_conv, 'approve', 'demonstration');
      end if;
      perform erp.transition_document(v_conv, 'send', 'demonstration');
$n$;
  -- 2. The requisition's own approval is decided before it is pressed.
  a2 constant text := $o$      perform erp.transition_document(v_doc, 'approve', 'demonstration');
      -- Ordered because an order was raised from it (20260922360000), not
$o$;
  b2 constant text := $n$      perform erp.approve_my_document_tasks(v_doc, 'demonstration');
      perform erp.transition_document(v_doc, 'approve', 'demonstration');
      -- Ordered because an order was raised from it (20260922360000), not
$n$;
  -- 3. A rejected requisition's task is refused before it is sent back.
  a3 constant text := $o$      perform erp.transition_document(v_doc, 'reject', 'Not in this quarter''s budget');
$o$;
  b3 constant text := $n$      perform erp.decide_approval_task(t.id, false, 'Not in this quarter''s budget')
         from erp.approval_task t
         join erp.approval_request q
           on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
        where q.tenant_id = v_tenant and q.object_type = 'document' and q.object_id = v_doc
          and q.status = 'pending' and t.status = 'pending'
          and t.assignee_user_id = erp.current_principal_id();
      perform erp.transition_document(v_doc, 'reject', 'Not in this quarter''s budget');
$n$;
  -- 4. D3: the requisition names the supplier its first product is bought from.
  a4 constant text := $o$    perform erp.transition_document(v_doc, 'submit', 'demonstration');
    v_roll := random()::numeric;
$o$;
  b4 constant text := $n$    -- Asked of the supplier its first product is bought from, the one the
    -- conversion below orders from, so the order is approved with it
    -- (20260922380000). One update and no random(): the seeder seeds its
    -- generator per day.
    update erp.document d
       set party_id = p.id,
           party_role_id = (select pr.id from erp.party_role pr
                             where pr.tenant_id = d.tenant_id and pr.party_id = p.id
                               and pr.role_kind = 'supplier' limit 1)
      from erp.document_line dl
      join erp.item i on i.tenant_id = dl.tenant_id and i.id = dl.item_id
      join erp.party p on p.tenant_id = i.tenant_id and p.code = i.attributes -> 'demo' ->> 'supplier'
     where d.tenant_id = v_tenant and d.id = v_doc
       and dl.tenant_id = d.tenant_id and dl.document_id = d.id
       and dl.line_no = (select min(l2.line_no) from erp.document_line l2
                          where l2.tenant_id = d.tenant_id and l2.document_id = d.id);
    perform erp.transition_document(v_doc, 'submit', 'demonstration');
    v_roll := random()::numeric;
$n$;
  n integer;
begin
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1),
      (length(v_def) - length(replace(v_def, a2, ''))) / length(a2),
      (length(v_def) - length(replace(v_def, a3, ''))) / length(a3),
      (length(v_def) - length(replace(v_def, a4, ''))) / length(a4)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(replace(replace(v_def, a1, b1), a2, b2), a3, b3), a4, b4);
end
$seed$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. The born-approved order
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.document_line_fingerprint(p_document_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select md5(coalesce(string_agg(
           jsonb_build_array(dl.id, dl.item_id, dl.description, dl.quantity, dl.uom_id,
                             dl.unit_price_minor, dl.discount_pct, dl.currency,
                             dl.is_cancelled)::text,
           E'\n' order by dl.id), ''))
    from erp.document_line dl
   where dl.tenant_id = erp.current_tenant_id()
     and dl.document_id = p_document_id
$$;

create or replace function erp.request_document_approval_or_inherit(
  p_document_id uuid, p_context jsonb default '{}'::jsonb,
  p_entity_id uuid default null, p_site_id uuid default null)
returns uuid
language plpgsql
set search_path = ''
as $$
begin
  -- Asked every time (20260922320000). W1 answered a submit from the
  -- document's own standing approval or from a parent's, followed through
  -- erp.document_relation — which any buyer can write between any two
  -- documents, so one decision approved any number of orders. Inheritance
  -- belongs where the child is created by the conversion that knows its
  -- parent (20260922380000, erp.conversion_keeps_approval), which reads the
  -- line fingerprint recorded here to know the lines were not changed since.
  return erp.request_approval('document', p_document_id,
           coalesce(p_context, '{}'::jsonb)
             || jsonb_build_object('line_fingerprint', erp.document_line_fingerprint(p_document_id)),
           1, p_entity_id, p_site_id);
end;
$$;

create or replace function erp.conversion_keeps_approval(p_order_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
-- Whether the purchase order p_order_id, being raised now by a conversion,
-- carries the approval of the requisition it was converted from
-- (20260922380000). Each test returns holds false and names itself; they run
-- in the order the header of this migration gives. Read by
-- erp.convert_document() before it makes the move, and again by
-- erp.transition_document() as the move is made.
declare
  v_tenant uuid := erp.require_tenant_id();
  o        erp.document%rowtype;
  rq       erp.document%rowtype;
  q        erp.approval_request%rowtype;
  v_req_id uuid;
  v_n      integer;
  v_cum    numeric;
  v_over   numeric;
  v_lines  integer;
  v_bad    boolean;
begin
  select * into o from erp.document d where d.tenant_id = v_tenant and d.id = p_order_id;
  if not found then
    return jsonb_build_object('holds', false, 'reason', 'order_not_found');
  end if;
  if o.is_cancelled or not exists (
       select 1 from erp.document_type dt
        where dt.tenant_id = v_tenant and dt.id = o.document_type_id
          and dt.base_type_code = 'purchase_order') then
    return jsonb_build_object('holds', false, 'reason', 'not_an_open_purchase_order');
  end if;

  if o.created_at is distinct from now() then
    return jsonb_build_object('holds', false, 'reason', 'not_created_in_this_transaction');
  end if;
  if coalesce(erp.object_current_state('document', p_order_id), '') <> 'draft'
     or exists (select 1 from erp.state_transition_log l
                 where l.tenant_id = v_tenant and l.object_type = 'document'
                   and l.object_id = p_order_id and l.transition_code is not null) then
    return jsonb_build_object('holds', false, 'reason', 'order_has_moved');
  end if;
  if exists (select 1 from erp.approval_request ar
              where ar.tenant_id = v_tenant
                and ((ar.object_type = 'document' and ar.object_id = p_order_id)
                  or (ar.object_type = 'document_line' and ar.object_id in (
                        select dl.id from erp.document_line dl
                         where dl.tenant_id = v_tenant and dl.document_id = p_order_id)))) then
    return jsonb_build_object('holds', false, 'reason', 'order_has_approval_request');
  end if;

  select count(distinct r.to_document_id), min(r.to_document_id::text)::uuid
    into v_n, v_req_id
    from erp.document_relation r
   where r.tenant_id = v_tenant and r.from_document_id = p_order_id;
  if v_n <> 1 then
    return jsonb_build_object('holds', false, 'reason', 'lineage_not_one_requisition');
  end if;
  if exists (select 1 from erp.document_relation r
              where r.tenant_id = v_tenant and r.from_document_id = p_order_id
                and (r.relation_kind <> 'converts' or r.from_line_id is null or r.to_line_id is null
                     or not exists (select 1 from erp.document_line rl
                                     where rl.tenant_id = v_tenant and rl.id = r.to_line_id
                                       and rl.document_id = v_req_id and not rl.is_cancelled)
                     or not exists (select 1 from erp.document_line ol
                                     where ol.tenant_id = v_tenant and ol.id = r.from_line_id
                                       and ol.document_id = p_order_id)))
     or exists (select 1 from erp.document_relation r
                 where r.tenant_id = v_tenant and r.to_document_id = p_order_id) then
    return jsonb_build_object('holds', false, 'reason', 'lineage_not_line_level');
  end if;
  -- Each order line is its requisition line, carried: the same item, unit,
  -- price, discount and words, and no more than the relation's quantity.
  if not exists (select 1 from erp.document_line ol
                  where ol.tenant_id = v_tenant and ol.document_id = p_order_id)
     or exists (
       select 1 from erp.document_line ol
        where ol.tenant_id = v_tenant and ol.document_id = p_order_id
          and (ol.is_cancelled
               or ol.quantity is null or ol.quantity <= 0
               or ol.unit_price_minor is null or ol.unit_price_minor <= 0
               or ol.net_minor is null or ol.net_minor <= 0
               or (select count(*) from erp.document_relation r
                    where r.tenant_id = v_tenant and r.from_line_id = ol.id) <> 1
               or exists (select 1 from erp.document_relation r
                            join erp.document_line rl on rl.tenant_id = r.tenant_id and rl.id = r.to_line_id
                           where r.tenant_id = v_tenant and r.from_line_id = ol.id
                             and (r.quantity is null or ol.quantity > r.quantity
                                  or ol.item_id is distinct from rl.item_id
                                  or ol.uom_id is distinct from rl.uom_id
                                  or ol.unit_price_minor is distinct from rl.unit_price_minor
                                  or coalesce(ol.discount_pct, 0) <> coalesce(rl.discount_pct, 0)
                                  or ol.description is distinct from rl.description)))) then
    return jsonb_build_object('holds', false, 'reason', 'order_line_not_carried');
  end if;

  select * into rq from erp.document d where d.tenant_id = v_tenant and d.id = v_req_id;
  if not found or rq.is_cancelled or not exists (
       select 1 from erp.document_type dt
        where dt.tenant_id = v_tenant and dt.id = rq.document_type_id
          and dt.base_type_code = 'requisition') then
    return jsonb_build_object('holds', false, 'reason', 'not_from_a_requisition');
  end if;
  if coalesce(erp.object_current_state('document', v_req_id), '') not in ('approved', 'ordered') then
    return jsonb_build_object('holds', false, 'reason', 'requisition_not_approved');
  end if;
  if exists (select 1 from erp.document_line rl
              where rl.tenant_id = v_tenant and rl.document_id = v_req_id and not rl.is_cancelled
                and (rl.quantity is null or rl.quantity <= 0
                     or rl.unit_price_minor is null or rl.unit_price_minor <= 0
                     or rl.net_minor is null or rl.net_minor <= 0)) then
    return jsonb_build_object('holds', false, 'reason', 'requisition_line_not_positive');
  end if;

  select ar.* into q
    from erp.approval_request ar
   where ar.tenant_id = v_tenant and ar.object_type = 'document'
     and ar.object_id = v_req_id and ar.status = 'approved'
   order by ar.requested_at desc, ar.decided_at desc nulls last
   limit 1;
  if not found then
    return jsonb_build_object('holds', false, 'reason', 'no_approved_request');
  end if;
  if exists (select 1 from erp.approval_request ar
              where ar.tenant_id = v_tenant and ar.object_type = 'document'
                and ar.object_id = v_req_id and ar.id <> q.id
                and ar.status in ('pending', 'rejected')
                and ar.requested_at >= q.requested_at) then
    return jsonb_build_object('holds', false, 'reason', 'latest_request_not_approved');
  end if;
  if not exists (select 1 from erp.approval_task t
                  where t.tenant_id = v_tenant and t.approval_request_id = q.id
                    and t.status = 'approved' and t.decided_by is not null)
     or exists (select 1 from erp.approval_task t
                 where t.tenant_id = v_tenant and t.approval_request_id = q.id
                   and t.status = 'rejected') then
    return jsonb_build_object('holds', false, 'reason', 'approved_by_nobody');
  end if;
  -- D2, fail closed: in a live organisation an approval the requester gave
  -- themselves (the administrator override) is theirs alone, and an order
  -- nobody else has looked at is not approved by it.
  if erp.tenant_is_live(v_tenant)
     and not exists (select 1 from erp.approval_task t
                      where t.tenant_id = v_tenant and t.approval_request_id = q.id
                        and t.status = 'approved'
                        and t.decided_by is distinct from q.requested_by) then
    return jsonb_build_object('holds', false, 'reason', 'approved_by_its_requester');
  end if;
  if q.value_at_approval is null or q.value_at_approval <= 0 then
    return jsonb_build_object('holds', false, 'reason', 'no_value_at_approval');
  end if;
  if (q.context ->> 'line_fingerprint') is null
     or (q.context ->> 'line_fingerprint') <> erp.document_line_fingerprint(v_req_id)
     or erp.document_value_minor(v_req_id) <> q.value_at_approval then
    return jsonb_build_object('holds', false, 'reason', 'lines_changed_since_approval');
  end if;
  -- Written after it was asked about, in a later transaction: an approver may
  -- have been shown something else, even if it has been put back since.
  if exists (select 1 from erp.document_line rl
              where rl.tenant_id = v_tenant and rl.document_id = v_req_id
                and (rl.created_at > q.requested_at or rl.updated_at > q.requested_at)) then
    return jsonb_build_object('holds', false, 'reason', 'requisition_changed_since_request');
  end if;

  if rq.currency is null
     or o.currency is distinct from rq.currency
     or (q.context ->> 'currency') is distinct from rq.currency::text
     or exists (select 1 from erp.document_line l
                 where l.tenant_id = v_tenant and l.document_id in (p_order_id, v_req_id)
                   and not l.is_cancelled and l.currency is distinct from rq.currency) then
    return jsonb_build_object('holds', false, 'reason', 'currency_differs');
  end if;

  if rq.party_id is null then
    return jsonb_build_object('holds', false, 'reason', 'no_supplier_named');
  end if;
  if o.party_id is distinct from rq.party_id
     or (q.context ->> 'party_id') is distinct from rq.party_id::text then
    return jsonb_build_object('holds', false, 'reason', 'supplier_differs');
  end if;
  if o.entity_id is distinct from rq.entity_id then
    return jsonb_build_object('holds', false, 'reason', 'entity_differs');
  end if;
  if o.site_id is distinct from rq.site_id then
    return jsonb_build_object('holds', false, 'reason', 'site_differs');
  end if;

  with fam as (
    select distinct ol.document_id as order_id
      from erp.document_relation r
      join erp.document_line rl on rl.tenant_id = r.tenant_id and rl.id = r.to_line_id
      join erp.document_line ol on ol.tenant_id = r.tenant_id and ol.id = r.from_line_id
      join erp.document od on od.tenant_id = ol.tenant_id and od.id = ol.document_id
     where r.tenant_id = v_tenant and r.relation_kind = 'converts'
       and r.to_document_id = v_req_id and rl.document_id = v_req_id
       and not od.is_cancelled
       and coalesce(erp.object_current_state('document', od.id), '') <> 'cancelled')
  select coalesce(sum(erp.document_value_minor(f.order_id)), 0),
         bool_or(exists (select 1 from erp.document od join erp.document_line l
                           on l.tenant_id = od.tenant_id and l.document_id = od.id
                          where od.tenant_id = v_tenant and od.id = f.order_id and not l.is_cancelled
                            and (od.currency is distinct from rq.currency
                                 or l.currency is distinct from rq.currency
                                 or coalesce(l.net_minor, 0) <= 0))),
         coalesce(sum((select count(*) from erp.document_line l
                        where l.tenant_id = v_tenant and l.document_id = f.order_id
                          and not l.is_cancelled)), 0)
    into v_cum, v_bad, v_lines
    from fam f;
  if coalesce(v_bad, true) then
    return jsonb_build_object('holds', false, 'reason', 'family_not_comparable');
  end if;

  -- D6, recommended: rounding only. Every carried line is priced as it was
  -- approved, so each line's round() is the only way the family can exceed.
  v_over := v_cum - q.value_at_approval;
  if v_over > v_lines then
    return jsonb_build_object('holds', false, 'reason', 'over_approved_value',
                              'ordered_value_minor', v_cum, 'value_at_approval', q.value_at_approval);
  end if;

  return jsonb_build_object(
    'holds', true, 'reason', null,
    'requisition_id', v_req_id, 'requisition_number', rq.document_number,
    'approval_request_id', q.id, 'value_at_approval', q.value_at_approval,
    'ordered_value_minor', v_cum, 'currency', rq.currency, 'party_id', rq.party_id,
    'line_fingerprint', q.context ->> 'line_fingerprint',
    'order_line_fingerprint', erp.document_line_fingerprint(p_order_id),
    'order_value_minor', erp.document_value_minor(p_order_id));
end $$;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values ('document.approval_carried', 1, 'document', 'procurement', 'event.document.approval_carried',
  'A purchase order was approved as the requisition it was converted from, by the conversion that raised it.',
  jsonb_build_object('type','object',
    'required', jsonb_build_array('requisition_id','approval_request_id','value_at_approval','ordered_value_minor',
                                  'currency','party_id','order_line_fingerprint','order_value_minor'),
    'properties', jsonb_build_object(
      'requisition_id', jsonb_build_object('type','string'),
      'requisition_number', jsonb_build_object('type','string'),
      'approval_request_id', jsonb_build_object('type','string'),
      'value_at_approval', jsonb_build_object('type','number'),
      'ordered_value_minor', jsonb_build_object('type','number'),
      'currency', jsonb_build_object('type','string'),
      'party_id', jsonb_build_object('type','string'),
      'line_fingerprint', jsonb_build_object('type','string'),
      'order_line_fingerprint', jsonb_build_object('type','string'),
      'order_value_minor', jsonb_build_object('type','number'))), true)
on conflict (code, version) do nothing;
insert into erp_ref.resource (key, locale, value) values
  ('event.document.approval_carried', 'en', 'Order approved with its requisition'),
  ('event.document.approval_carried', 'de', 'Bestellung mit der Bedarfsanforderung genehmigt')
on conflict (key, locale) do nothing;

do $door$
declare
  v_def text := pg_get_functiondef('erp.transition_document(uuid,text,text)'::regprocedure);
  v_old_dec constant text := $o$  v_fact   boolean;
$o$;
  v_new_dec constant text := $n$  v_fact   boolean;
  v_carry  jsonb;
$n$;
  v_old constant text := $o$  -- A transfer advances on stock moving, not on somebody clicking
$o$;
  v_new constant text := $n$  if p_transition_code = 'inherit_approval' then
    if coalesce(current_setting('erp.carrying_approval', true), '') <> p_document_id::text then
      raise exception
        'CLOVEERP_APPROVAL_NOT_CARRIED: % is approved with its requisition only by the conversion that raises it',
        coalesce(d.document_number, p_document_id::text)
        using errcode = '23514',
              hint = 'Submit the order for its own approval. An order is approved with its requisition only as it is converted from it, unchanged and to the supplier the requisition named.';
    end if;
    v_carry := erp.conversion_keeps_approval(p_document_id);
    if not coalesce((v_carry ->> 'holds')::boolean, false) then
      raise exception 'CLOVEERP_APPROVAL_NOT_CARRIED: % is not approved with its requisition (%)',
        coalesce(d.document_number, p_document_id::text), coalesce(v_carry ->> 'reason', 'unknown')
        using errcode = '23514',
              hint = 'Submit the order for its own approval.';
    end if;
    perform erp.append_event('document.approval_carried', 'document', p_document_id,
      v_carry - 'holds' - 'reason', d.entity_id, d.site_id);
    v_carry := null;
  end if;

  -- D5 (a): an order approved with its requisition is issued as it was
  -- converted, or not at all.
  if dt.base_type_code = 'purchase_order' and p_transition_code = 'send' then
    select ev.payload into v_carry
      from erp.event ev
     where ev.tenant_id = v_tenant and ev.aggregate_type = 'document'
       and ev.aggregate_id = p_document_id
       and ev.event_type = 'document.approval_carried'
     order by ev.global_seq desc
     limit 1;
    if v_carry is not null
       and ((v_carry ->> 'order_line_fingerprint') is distinct from erp.document_line_fingerprint(p_document_id)
            or (v_carry ->> 'order_value_minor')::bigint is distinct from erp.document_value_minor(p_document_id)) then
      raise exception
        'CLOVEERP_CARRIED_ORDER_CHANGED: % has changed since it was approved with its requisition',
        coalesce(d.document_number, p_document_id::text)
        using errcode = '23514',
              hint = 'Put the order back as it was converted, or have an approver cancel it and raise it again for its own approval.';
    end if;
    v_carry := null;
  end if;

  -- A transfer advances on stock moving, not on somebody clicking
$n$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: erp.transition_document carry anchor'; end if;
  if (length(v_def) - length(replace(v_def, v_old_dec, ''))) / length(v_old_dec) <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: erp.transition_document declaration anchor'; end if;
  execute replace(replace(v_def, v_old_dec, v_new_dec), v_old, v_new);
end $door$;

do $convert$
declare
  v_def text := pg_get_functiondef('erp.convert_document(uuid,uuid,uuid,jsonb,text)'::regprocedure);
  a_dec constant text := $o$  v_source   text := null;
$o$;
  b_dec constant text := $n$  v_source   text := null;
  v_carry    jsonb := null;
$n$;
  a_top constant text := $o$  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
$o$;
  b_top constant text := $n$  if p_transition = 'inherit_approval' then
    raise exception 'CLOVEERP_APPROVAL_NOT_CARRIED: an order is approved with its requisition by the conversion, not by naming the move'
      using errcode = '23514',
            hint = 'Convert without naming a move. The order is approved with its requisition when the requisition named its supplier and the order keeps it; otherwise submit it for its own approval.';
  end if;
  perform pg_advisory_xact_lock(hashtext('erp.convert_document:' || v_tenant::text || ':' || p_document_id::text));

  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
$n$;
  a_carry constant text := $o$  -- What is left on the source, once this conversion is counted.
$o$;
  b_carry constant text := $n$  -- Approved with its requisition (M2), before the source's own move, so
  -- the check reads the requisition as its approver left it.
  if v_base = 'requisition'
     and exists (select 1 from erp.available_transitions('document', v_new,
                   erp.document_transition_context(v_new, 'inherit_approval')) at
                  where at.transition_code = 'inherit_approval' and at.permitted and at.guard_passes)
  then
    v_carry := erp.conversion_keeps_approval(v_new);
    if coalesce((v_carry ->> 'holds')::boolean, false) then
      perform set_config('erp.carrying_approval', v_new::text, true);
      perform erp.transition_document(v_new, 'inherit_approval', 'Approved with ' || d.document_number);
      perform set_config('erp.carrying_approval', '', true);
      v_moved := 'inherit_approval';
    end if;
  end if;

  -- What is left on the source, once this conversion is counted.
$n$;
  a_mv constant text := $o$  if coalesce(p_transition, '') <> '' then
$o$;
  b_mv constant text := $n$  if coalesce(p_transition, '') <> '' and v_moved is null then
$n$;
  a_ret constant text := $o$    'moved_on', v_moved);
$o$;
  b_ret constant text := $n$    'moved_on', v_moved,
    'born_approved', coalesce(v_moved = 'inherit_approval', false),
    'approval_carried_from', case when v_moved = 'inherit_approval' then v_carry ->> 'approval_request_id' end,
    'approval_not_carried', case when coalesce((v_carry ->> 'holds')::boolean, false) then null
                                 else v_carry ->> 'reason' end);
$n$;
  n int;
  v_after text;
begin
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a_dec, ''))) / length(a_dec),
      (length(v_def) - length(replace(v_def, a_top, ''))) / length(a_top),
      (length(v_def) - length(replace(v_def, a_carry, ''))) / length(a_carry),
      (length(v_def) - length(replace(v_def, a_mv, ''))) / length(a_mv),
      (length(v_def) - length(replace(v_def, a_ret, ''))) / length(a_ret)] loop
    if n <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: erp.convert_document anchor found % time(s)', n; end if;
  end loop;
  execute replace(replace(replace(replace(replace(v_def, a_dec, b_dec), a_top, b_top), a_carry, b_carry), a_mv, b_mv), a_ret, b_ret);
  v_after := pg_get_functiondef('erp.convert_document(uuid,uuid,uuid,jsonb,text)'::regprocedure);
  if position('erp.document_is_fully_converted(p_document_id)' in v_after) = 0 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.convert_document lost 20260922360000''s fact';
  end if;
end $convert$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4b. PR4 decision 6: a move the system derives takes its authority from
-- the fact, not from whoever set it off
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- A4b.1 The fact, asked where the permission is asked
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.derived_move_fact(p_object_type text, p_object_id uuid,
                                                 p_transition_code text)
returns text
language sql
stable
set search_path = ''
as $$
  -- The fact a move is derived from, when the system is making it, and null
  -- in every other case (decision 6, 20260922380000). Two moves, each asked
  -- for by one routine, which names the document and the move in
  -- erp.deriving_move immediately before it asks and clears it immediately
  -- after:
  --
  --   a purchase order's close   erp.close_order_when_settled(), from the
  --                              bill, the receipt and the received hook
  --   a requisition's order      erp.convert_document()
  --
  -- The routine's own test is not trusted. The fact is read again here, by
  -- the same two functions, with the object's state row already locked by
  -- erp.perform_transition(). Any other move, object or document type, a
  -- cancelled document and a fact that no longer holds return null, and the
  -- person's own permission is all there is, as it always was.
  select case
           when dt.base_type_code = 'purchase_order' and p_transition_code = 'close'
            and erp.object_current_state('document', p_object_id) = 'received'
            and erp.order_is_settled(p_object_id)
             then 'erp.order_is_settled'
           when dt.base_type_code = 'requisition' and p_transition_code = 'order'
            and erp.document_is_fully_converted(p_object_id)
             then 'erp.document_is_fully_converted'
         end
    from erp.document d
    join erp.document_type dt
      on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where p_object_type = 'document'
     and coalesce(current_setting('erp.deriving_move', true), '')
           = p_object_id::text || ':' || p_transition_code
     and d.tenant_id = erp.current_tenant_id()
     and d.id = p_object_id
     and not d.is_cancelled
$$;

comment on function erp.derived_move_fact(text, uuid, text) is
  'The fact a move the system derives takes its authority from, or null '
  '(decision 6, 20260922380000): erp.order_is_settled for a received purchase '
  'order''s close asked for by erp.close_order_when_settled(), and '
  'erp.document_is_fully_converted for a requisition''s order asked for by '
  'erp.convert_document(). Read by erp.perform_transition(), which answers only '
  'the permission refusal of erp.authorise() with it.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A4b.2 The engine asks the person, and answers only the permission with the fact
-- ─────────────────────────────────────────────────────────────────────────────

do $perform$
declare
  v_sig constant text := 'erp.perform_transition(text,uuid,text,jsonb,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_hits integer;
  v_old_dec constant text := $o$  v_effects  jsonb;
$o$;
  v_new_dec constant text := $n$  v_effects  jsonb;
  v_derived  text;
  v_permitted boolean;
$n$;
  v_old_auth constant text := $o$  if v_t.required_permission is not null then
    perform erp.authorise(v_t.required_permission, v_os.entity_id, v_os.site_id,
                          null, p_object_type, p_object_id);
  end if;
$o$;
  v_new_auth constant text := $n$  -- A move the system derives takes its authority from the fact, not from
  -- whoever set it off (decision 6, 20260922380000). erp.derived_move_fact()
  -- names the fact only for the two moves a routine asked for by name, and
  -- only while the fact holds, read now with this object's state locked
  -- above. The person is still asked first, so everything erp.authorise()
  -- applies before the permission (the entry point, the platform owner, an
  -- organisation restricted or suspended, and whatever it applies later)
  -- applies to a derived move as well. Only its CLOVEERP_PERMISSION_DENIED is
  -- answered by the fact: the refusal is rolled back with the block and the
  -- grant is written instead, against the person, with the fact as its
  -- reason. Every other move is authorised as it always has been.
  if v_t.required_permission is not null then
    v_derived := erp.derived_move_fact(p_object_type, p_object_id, p_transition_code);
    if v_derived is null then
      perform erp.authorise(v_t.required_permission, v_os.entity_id, v_os.site_id,
                            null, p_object_type, p_object_id);
    else
      begin
        perform erp.authorise(v_t.required_permission, v_os.entity_id, v_os.site_id,
                              null, p_object_type, p_object_id);
        v_permitted := true;
      exception when insufficient_privilege then
        if sqlerrm not like 'CLOVEERP_PERMISSION_DENIED:%' then
          raise;
        end if;
        v_permitted := false;
        perform erp.log_access_decision(
          v_t.required_permission, true, v_os.entity_id, v_os.site_id, null,
          p_object_type, p_object_id,
          format('derived from %s: the system''s move, made on this person''s action', v_derived));
      end;
    end if;
  end if;
$n$;
  v_old_log constant text := $o$    v_from, v_to, erp.current_principal_id(), p_reason, p_data,
$o$;
  v_new_log constant text := $n$    v_from, v_to, erp.current_principal_id(), p_reason,
    -- The log says the move was derived, from what, and whether the person
    -- recorded as its actor could have made it themselves.
    case when v_derived is null then p_data
         else coalesce(p_data, '{}'::jsonb) || jsonb_build_object('derived', jsonb_build_object(
                'fact', v_derived,
                'permission', v_t.required_permission,
                'actor_permitted', v_permitted))
    end,
$n$;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old_dec, ''))) / length(v_old_dec);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % declaration anchor found % time(s)', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old_auth, ''))) / length(v_old_auth);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % authorise anchor found % time(s)', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old_log, ''))) / length(v_old_log);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % log anchor found % time(s)', v_sig, v_hits;
  end if;

  execute replace(replace(replace(v_def, v_old_dec, v_new_dec),
                          v_old_auth, v_new_auth),
                  v_old_log, v_new_log);
end
$perform$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4b.3 The close the bill derives: M1's routine, restated with its marker
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.close_order_when_settled(p_order_id uuid, p_reason text)
returns boolean
language plpgsql
set search_path = ''
as $$
begin
  -- Only a received order closes, and only when its bill is in. Anything else
  -- is not this routine's business, and asking twice is harmless.
  if erp.object_current_state('document', p_order_id) is distinct from 'received'
     or not erp.order_is_settled(p_order_id) then
    return false;
  end if;

  -- The close is the system's, derived from the bill (decision 6,
  -- 20260922380000), so it does not wait for somebody who may close orders:
  -- the receipt poster or the bill's registrar is recorded as its actor, and
  -- needs no permission of their own for it. The order and the move are named
  -- immediately before the move and cleared immediately after, and
  -- erp.derived_move_fact() reads the fact again inside the door rather than
  -- trusting the test above. Named inside the block, so the refusal's
  -- rollback takes the name with it as well as the handler's clear.
  --
  -- The bill or the receipt is already committed. If the order still cannot
  -- close (a lifecycle with no such move, a restricted organisation) that is
  -- worth recording, not worth undoing the bill for.
  begin
    perform set_config('erp.deriving_move', p_order_id::text || ':close', true);
    perform erp.transition_document(p_order_id, 'close', p_reason);
    perform set_config('erp.deriving_move', '', true);
    return true;
  exception when others then
    perform set_config('erp.deriving_move', '', true);
    perform erp.append_event(
      'document.progress_not_advanced', 'document', p_order_id,
      jsonb_build_object('transition', 'close', 'reason', sqlerrm),
      null, null);
    return false;
  end;
end $$;

comment on function erp.close_order_when_settled(uuid, text) is
  'Closes a received purchase order whose goods have all been billed, and '
  'records rather than raises a refusal (20260922360000). Called by the bill '
  '(erp.close_orders_billed_by), by the receipt that completes an order billed '
  'first (erp.advance_orders_for_receipt) and by the door when an order reaches '
  'Received (20260922370000). The close takes its authority from '
  'erp.order_is_settled(), not from the person whose action set it off '
  '(decision 6, 20260922380000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- A4b.4 The requisition's order the conversion derives, and the one M1 left
-- ─────────────────────────────────────────────────────────────────────────────

do $convert_order$
declare
  v_sig constant text := 'erp.convert_document(uuid,uuid,uuid,jsonb,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_hits integer;
  v_old constant text := $o$     where at.guard_passes and at.permitted and at.to_state in ('ordered', 'accepted')
     limit 1;

    if v_source is not null then
      perform erp.transition_document(p_document_id, v_source, 'Converted into an order');
    end if;
$o$;
  v_new constant text := $n$     where at.guard_passes and at.to_state in ('ordered', 'accepted')
       -- A requisition's order is the system's, derived from the conversion
       -- (decision 6, 20260922380000), so it is not left undone because the
       -- person converting may not order at the requisition's own site. A
       -- quotation's acceptance is still the person's to make.
       and (at.permitted or (v_base = 'requisition' and at.transition_code = 'order'))
     limit 1;

    if v_source is not null and v_base = 'requisition' and v_source = 'order' then
      -- Named immediately before the move and cleared immediately after;
      -- erp.derived_move_fact() reads the fact again inside the door.
      begin
        perform set_config('erp.deriving_move', p_document_id::text || ':order', true);
        perform erp.transition_document(p_document_id, v_source, 'Converted into an order');
        perform set_config('erp.deriving_move', '', true);
      exception when others then
        perform set_config('erp.deriving_move', '', true);
        raise;
      end;
    elsif v_source is not null then
      perform erp.transition_document(p_document_id, v_source, 'Converted into an order');
    end if;
$n$;
  v_old_again constant text := $o$  v_new := erp.open_document(v_type, v_party, null, v_site,
$o$;
  v_new_again constant text := $n$  -- A requisition every line of which is already on an order, still reading
  -- Approved: what M1 left where the person converting might not order at
  -- the requisition's own site (decision 6, 20260922380000). Converting it
  -- again raises no order and makes the move the first conversion would have
  -- made, asked of whoever may raise the order, as a conversion asks.
  if v_base = 'requisition' and erp.document_is_fully_converted(p_document_id) then
    select at.transition_code into v_source
      from erp.available_transitions('document', p_document_id,
             erp.document_transition_context(p_document_id, null)) at
     where at.guard_passes and at.transition_code = 'order' and at.to_state = 'ordered'
     limit 1;

    if v_source is not null then
      perform erp.authorise(
        (select coalesce(tdt.create_permission, bt.create_permission)
           from erp.document_type tdt where tdt.tenant_id = v_tenant and tdt.code = v_type),
        (select tdt.entity_id from erp.document_type tdt
          where tdt.tenant_id = v_tenant and tdt.code = v_type),
        v_site, null, 'document', p_document_id);
      begin
        perform set_config('erp.deriving_move', p_document_id::text || ':order', true);
        perform erp.transition_document(p_document_id, v_source, 'Converted into an order');
        perform set_config('erp.deriving_move', '', true);
      exception when others then
        perform set_config('erp.deriving_move', '', true);
        raise;
      end;
      return jsonb_build_object(
        'document_id', null,
        'document_number', null,
        'source_document_number', d.document_number,
        'lines', 0,
        'outstanding_on_source', 0,
        'source_moved_on', v_source,
        'moved_on', null,
        'born_approved', false,
        'approval_carried_from', null,
        'approval_not_carried', null);
    end if;
  end if;

  v_new := erp.open_document(v_type, v_party, null, v_site,
$n$;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % source move anchor found % time(s)', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old_again, ''))) / length(v_old_again);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % open anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(replace(v_def, v_old, v_new), v_old_again, v_new_again);

  if position('erp.document_is_fully_converted(p_document_id)'
              in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % lost 20260922360000''s fact', v_sig;
  end if;
end
$convert_order$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4b.5 The bill the fact reads
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.invoice_against(p_invoice_id uuid, p_order_line_id uuid,
                                              p_quantity numeric,
                                              p_unit_price_minor bigint default null)
returns erp.match_status
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  ol       erp.document_line%rowtype;
  od       erp.document%rowtype;
  bd       erp.document%rowtype;
  a        record;
  v_line   uuid;
  v_no     integer;
begin
  select * into ol from erp.document_line
   where tenant_id = v_tenant and id = p_order_line_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_LINE: %', p_order_line_id using errcode = '23503';
  end if;

  select * into od from erp.document where tenant_id = v_tenant and id = ol.document_id;

  perform erp.authorise('procurement.match', od.entity_id, od.site_id, null,
                        'document', p_invoice_id);

  -- The bill is what erp.order_is_settled() reads, and a settled order closes
  -- itself whoever moved the bill (decision 6, 20260922380000). So a line is
  -- invoiced only onto a supplier's bill (a sales invoice shares its base
  -- type), from the order's own supplier, and only while that bill can still
  -- be changed: once it has posted, a line added to it settles the order with
  -- nothing owed for it.
  select * into bd from erp.document where tenant_id = v_tenant and id = p_invoice_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_invoice_id using errcode = '23503';
  end if;

  if bd.party_id is distinct from od.party_id
     or not erp.document_is_purchase_bill(p_invoice_id) then
    raise exception 'CLOVEERP_BILL_FROM_ANOTHER_SUPPLIER: % is not a bill from the supplier % is ordered from',
      coalesce(bd.document_number, p_invoice_id::text), coalesce(od.document_number, od.id::text)
      using errcode = '23514',
            hint = 'Invoice the order on a bill from its own supplier. A bill from anyone else settles nothing on it.';
  end if;

  select * into a from erp.amendment_allowed(p_invoice_id);
  if not a.allowed then
    raise exception 'CLOVEERP_PAST_AMENDMENT_CUT_OFF: % — %', a.cut_off, a.detail
      using errcode = '42501',
            hint = 'Raise a new bill for what this one left out, or a credit note for what it got wrong.';
  end if;

  select coalesce(max(l.line_no), 0) + 1 into v_no
    from erp.document_line l
   where l.tenant_id = v_tenant and l.document_id = p_invoice_id;

  insert into erp.document_line (
    tenant_id, document_id, line_no, item_id, description, quantity, uom_id,
    unit_price_minor, net_minor, currency)
  values (v_tenant, p_invoice_id, v_no, ol.item_id,
          coalesce(ol.description, 'invoiced'), p_quantity, ol.uom_id,
          coalesce(p_unit_price_minor, ol.unit_price_minor),
          round(p_quantity * coalesce(p_unit_price_minor, ol.unit_price_minor))::bigint,
          coalesce(ol.currency, od.currency))
  returning id into v_line;

  insert into erp.document_relation (
    tenant_id, from_document_id, to_document_id, relation_kind,
    from_line_id, to_line_id, quantity)
  values (v_tenant, p_invoice_id, ol.document_id, 'invoices',
          v_line, p_order_line_id, p_quantity);

  -- Matching on the way in rather than in a nightly job. An exception found
  -- three days later is one somebody has already paid.
  return erp.match_three_way(p_order_line_id);
end;
$$;

do $amend$
declare
  v_sig constant text := 'erp.amend_document_line(uuid,numeric,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_hits integer;
  v_old_dec constant text := $o$  v_perm   text;
$o$;
  v_new_dec constant text := $n$  v_perm   text;
  v_inv    record;
$n$;
  v_old constant text := $o$         updated_at = now()
   where id = p_line_id;
$o$;
  v_new constant text := $n$         updated_at = now()
   where id = p_line_id;

  -- A bill line matched to an order line is counted through its relation, by
  -- erp.order_is_settled() and erp.grni_report() (20260922380000). The
  -- relation follows the line and the match is asked again, so a bill cannot
  -- settle what it no longer charges for.
  for v_inv in
    select rel.id, rel.to_line_id from erp.document_relation rel
      join erp.document_line ol on ol.tenant_id = rel.tenant_id and ol.id = rel.to_line_id
      join erp.document o on o.tenant_id = ol.tenant_id and o.id = ol.document_id
      join erp.document_type odt on odt.tenant_id = o.tenant_id and odt.id = o.document_type_id
     where rel.tenant_id = v_tenant and rel.from_line_id = p_line_id
       and rel.relation_kind = 'invoices'
       and odt.base_type_code = 'purchase_order'
       and erp.document_is_purchase_bill(rel.from_document_id)
  loop
    update erp.document_relation set quantity = p_quantity
     where tenant_id = v_tenant and id = v_inv.id;
    perform erp.match_three_way(v_inv.to_line_id);
  end loop;
$n$;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old_dec, ''))) / length(v_old_dec);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % declaration anchor found % time(s)', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % line anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(replace(v_def, v_old_dec, v_new_dec), v_old, v_new);
end
$amend$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4b.5b What settles an order: a supplier's bill that charges for what it
-- invoices
--
-- Found on review: erp.order_is_settled() counted any committed document of
-- base type invoice_reference, which a sales invoice shares, and counted a
-- bill's matched quantity whatever else the bill said. A sales invoice to a
-- party who is also the supplier closed the purchase order, and a bill for ten
-- with an unmatched line of minus nine cleared ten received against a payable
-- of one. On main each left the order Received for somebody who may close it;
-- with decision 6 the close is derived, so the fact must not be writable that
-- way. A bill with any line that takes value off it settles nothing, and the
-- order waits for its credit note or a close by hand with the reason.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.document_is_purchase_bill(p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- A supplier's bill: an invoice_reference document on the supplier bill's
  -- own lifecycle (purchase_invoice), which is how erp.bill_from_receipt()
  -- tells it from a sales invoice. Anything else is not one.
  select coalesce((
    select dt.base_type_code = 'invoice_reference'
       and dt.state_machine_code = 'purchase_invoice'
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id), false)
$$;

create or replace function erp.bill_settles_orders(p_bill_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- A supplier's bill, not cancelled, none of whose lines takes value off it.
  -- What went back is a credit note's to say, not a negative line's.
  select erp.document_is_purchase_bill(p_bill_id)
     and exists (select 1 from erp.document b
                  where b.tenant_id = erp.current_tenant_id() and b.id = p_bill_id
                    and not b.is_cancelled)
     and not exists (select 1 from erp.document_line l
                      where l.tenant_id = erp.current_tenant_id() and l.document_id = p_bill_id
                        and not l.is_cancelled
                        and (l.quantity is null or l.quantity <= 0
                             or coalesce(l.net_minor, 0) < 0))
$$;

comment on function erp.bill_settles_orders(uuid) is
  'Whether a committed document may count towards erp.order_is_settled(): a '
  'supplier''s bill (erp.document_is_purchase_bill), not cancelled, with no line '
  'of zero or negative quantity or negative value (20260922380000).';

do $settled$
declare
  v_sig constant text := 'erp.order_is_settled(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$                and bdt.base_type_code = 'invoice_reference'
$o$;
  v_new constant text := $n$                and bdt.base_type_code = 'invoice_reference'
                -- A supplier's bill that charges for what it invoices
                -- (20260922380000): not a sales invoice, and not a bill with a
                -- line that takes value off it.
                and erp.bill_settles_orders(b.id)
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % bill anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$settled$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4b.6 No context setting outlives its transaction, whatever it is called
-- ─────────────────────────────────────────────────────────────────────────────

do $hygiene$
declare
  v_def text := pg_get_functiondef('erp.session_context_hygiene_report()'::regprocedure);
  v_old text := $p$''erp\.(job_tenant_id|job_principal_id|purge_tenant_id|promotion_id|correlation_id|ledger_write|source)''$p$;
  v_new text := $q$''erp\.[a-z_]+''$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp.session_context_hygiene_report() does not list the context settings where this migration expects'
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(v_def, v_old, v_new);
end
$hygiene$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. The register, and a code the current upgrade ships
--
-- Restated whole, because src/lib/stage-records.test.ts reads the newest
-- migration that defines it. One row is new: purchase_order.inherit_approval,
-- a routine row driven by erp.convert_document(). Its signature must not
-- change, or findings 3 and 4 of erp.undriven_transition_report() lose it.
--
-- Finding 5 reported a move no shipped installer declares. On production every
-- organisation holds version 1 when this commits, so nothing holds
-- inherit_approval yet and nothing the installer installs today names it.
-- It is excused while the installer's CURRENT upgrade payload declares it.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.transition_driver_register()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_agg(to_jsonb(x) order by x.machine_code, x.transition_code)
    from (values
      -- ── Procurement ───────────────────────────────────────────────────────
      ('requisition'::text,  'submit'::text,           'screen'::text, ''::text),
      ('requisition',        'approve',                'screen', ''),
      ('requisition',        'reject',                 'screen', ''),
      -- Ordered because an order was raised from all of it (20260922360000).
      -- The routine's move takes its authority from that fact, whatever
      -- permission the organisation puts on the move (PR4 decision 6, D8,
      -- 20260922380000); the permission governs only a move made by hand.
      ('requisition',        'order',                  'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('requisition',        'cancel',                 'screen', ''),
      ('requisition',        'cancel_submitted',       'screen', ''),

      ('purchase_order',     'submit',                 'screen', ''),
      ('purchase_order',     'approve',                'screen', ''),
      -- Approved with its requisition, by the conversion that raises it and
      -- by nothing else (20260922380000).
      ('purchase_order',     'inherit_approval',       'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('purchase_order',     'reject',                 'screen', ''),
      ('purchase_order',     'send',                   'screen', ''),
      ('purchase_order',     'receive_partial',        'routine', 'erp.advance_orders_for_receipt(uuid)'),
      -- The receipt makes it, and a person may, with a reason, when nothing
      -- more is coming (20260922360000).
      ('purchase_order',     'receive_rest',           'screen', ''),
      ('purchase_order',     'receive_all',            'routine', 'erp.advance_orders_for_receipt(uuid)'),
      -- The bill makes it (erp.close_order_when_settled), and a person may,
      -- with a reason, when the bill is kept elsewhere (20260922360000). The
      -- bill's close takes its authority from erp.order_is_settled(), whatever
      -- permission the organisation puts on the move (PR4 decision 6, D8,
      -- 20260922380000); the permission governs only the close by hand.
      ('purchase_order',     'close',                  'screen', ''),
      ('purchase_order',     'cancel',                 'screen', ''),
      ('purchase_order',     'cancel_approved',        'screen', ''),

      ('goods_receipt',      'post',                   'screen', ''),
      ('goods_receipt',      'cancel',                 'screen', ''),

      ('purchase_invoice',   'register',               'screen', ''),
      ('purchase_invoice',   'dispute',                'screen', ''),
      ('purchase_invoice',   'resolve',                'screen', ''),
      ('purchase_invoice',   'pay',                    'routine', 'erp.settle_paid_document(uuid,text)'),
      ('purchase_invoice',   'cancel',                 'screen', ''),

      ('purchase_credit_note', 'issue',                'screen', ''),
      ('purchase_credit_note', 'cancel',               'screen', ''),

      -- ── Sales ─────────────────────────────────────────────────────────────
      ('quotation',          'send',                   'screen', ''),
      ('quotation',          'accept',                 'screen', ''),
      ('quotation',          'decline',                'screen', ''),
      ('quotation',          'expire',                 'screen', ''),

      ('sales_order',        'submit',                 'screen', ''),
      ('sales_order',        'approve',                'screen', ''),
      ('sales_order',        'reject',                 'screen', ''),
      ('sales_order',        'pick',                   'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch',               'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'invoice',                'routine', 'erp.advance_orders_for_invoice(uuid)'),
      ('sales_order',        'close',                  'screen', ''),
      ('sales_order',        'cancel',                 'screen', ''),
      ('sales_order',        'cancel_confirmed',       'screen', ''),

      ('delivery',           'post',                   'screen', ''),
      ('delivery',           'cancel',                 'screen', ''),

      ('sales_invoice',      'issue',                  'screen', ''),
      ('sales_invoice',      'settle',                 'routine', 'erp.settle_paid_document(uuid,text)'),
      ('sales_invoice',      'credit',                 'routine', 'erp.credit_invoices_for_credit_note(uuid)'),
      ('sales_invoice',      'cancel',                 'screen', ''),

      ('sales_credit_note',  'issue',                  'screen', ''),
      ('sales_credit_note',  'cancel',                 'screen', ''),

      -- ── Commercial ────────────────────────────────────────────────────────
      ('commercial_quote',   'submit',                 'screen', ''),
      ('commercial_quote',   'approve',                'screen', ''),
      ('commercial_quote',   'reject',                 'screen', ''),
      ('commercial_quote',   'issue',                  'screen', ''),
      ('commercial_quote',   'accept',                 'screen', ''),
      ('commercial_quote',   'decline',                'screen', ''),
      ('commercial_quote',   'expire',                 'screen', ''),
      ('commercial_quote',   'supersede_draft',        'screen', ''),
      ('commercial_quote',   'supersede_approved',     'screen', ''),
      ('commercial_quote',   'supersede_issued',       'screen', ''),

      -- ── Inventory ─────────────────────────────────────────────────────────
      ('transfer_order',     'approved',               'screen', ''),
      ('transfer_order',     'issued',                 'screen', ''),
      ('transfer_order',     'in_transit',             'screen', ''),
      ('transfer_order',     'received',               'screen', ''),
      ('transfer_order',     'closed',                 'screen', ''),
      ('transfer_order',     'draft_to_discrepancy',   'screen', ''),
      ('transfer_order',     'approved_to_discrepancy','screen', ''),
      ('transfer_order',     'issued_to_discrepancy',  'screen', ''),
      ('transfer_order',     'in_transit_to_discrepancy', 'screen', ''),
      ('transfer_order',     'received_to_discrepancy','screen', ''),
      ('transfer_order',     'discrepancy_to_received','screen', ''),
      ('transfer_order',     'draft_to_cancelled',     'screen', ''),
      ('transfer_order',     'approved_to_cancelled',  'screen', ''),
      ('transfer_order',     'issued_to_cancelled',    'screen', ''),
      ('transfer_order',     'in_transit_to_cancelled','screen', ''),
      ('transfer_order',     'received_to_cancelled',  'screen', ''),

      ('stock_adjustment',   'approve',                'screen', ''),
      ('stock_adjustment',   'post',                   'screen', ''),
      ('stock_adjustment',   'cancel',                 'screen', ''),
      ('stock_adjustment',   'approved_to_cancelled',  'screen', ''),

      -- ── The base content pack's own document lifecycles ───────────────────
      -- Installed by applying the base pack rather than by a module installer
      -- (20260903160000, Starter Content Packs §5.1): the five nothing else
      -- creates, less the transfer order above, which the inventory installer
      -- now ships identically. None of them is left to a door, so the document
      -- page draws every move each one declares.
      ('works_order',          'firmed',                    'screen', ''),
      ('works_order',          'released',                  'screen', ''),
      ('works_order',          'in_progress',               'screen', ''),
      ('works_order',          'completed',                 'screen', ''),
      ('works_order',          'closed',                    'screen', ''),
      ('works_order',          'planned_to_held',           'screen', ''),
      ('works_order',          'firmed_to_held',            'screen', ''),
      ('works_order',          'released_to_held',          'screen', ''),
      ('works_order',          'in_progress_to_held',       'screen', ''),
      ('works_order',          'completed_to_held',         'screen', ''),
      ('works_order',          'held_to_released',          'screen', ''),
      ('works_order',          'planned_to_cancelled',      'screen', ''),
      ('works_order',          'firmed_to_cancelled',       'screen', ''),
      ('works_order',          'released_to_cancelled',     'screen', ''),
      ('works_order',          'in_progress_to_cancelled',  'screen', ''),
      ('works_order',          'completed_to_cancelled',    'screen', ''),
      ('works_order',          'planned_to_scrapped',       'screen', ''),
      ('works_order',          'firmed_to_scrapped',        'screen', ''),
      ('works_order',          'released_to_scrapped',      'screen', ''),
      ('works_order',          'in_progress_to_scrapped',   'screen', ''),
      ('works_order',          'completed_to_scrapped',     'screen', ''),
      ('count',                'in_progress',               'screen', ''),
      ('count',                'counted',                   'screen', ''),
      ('count',                'under_review',              'screen', ''),
      ('count',                'approved',                  'screen', ''),
      ('count',                'posted',                    'screen', ''),
      ('count',                'scheduled_to_recount',      'screen', ''),
      ('count',                'in_progress_to_recount',    'screen', ''),
      ('count',                'counted_to_recount',        'screen', ''),
      ('count',                'under_review_to_recount',   'screen', ''),
      ('count',                'approved_to_recount',       'screen', ''),
      ('count',                'recount_to_in_progress',    'screen', ''),
      ('count',                'scheduled_to_cancelled',    'screen', ''),
      ('count',                'in_progress_to_cancelled',  'screen', ''),
      ('count',                'counted_to_cancelled',      'screen', ''),
      ('count',                'under_review_to_cancelled', 'screen', ''),
      ('count',                'approved_to_cancelled',     'screen', ''),
      ('return',               'authorised',                'screen', ''),
      ('return',               'received',                  'screen', ''),
      ('return',               'inspected',                 'screen', ''),
      ('return',               'dispositioned',             'screen', ''),
      ('return',               'closed',                    'screen', ''),
      ('return',               'requested_to_refused',      'screen', ''),
      ('return',               'authorised_to_refused',     'screen', ''),
      ('return',               'received_to_refused',       'screen', ''),
      ('return',               'inspected_to_refused',      'screen', ''),
      ('return',               'dispositioned_to_refused',  'screen', ''),
      ('supplier_invoice',     'matched',                   'screen', ''),
      ('supplier_invoice',     'approved',                  'screen', ''),
      ('supplier_invoice',     'posted',                    'screen', ''),
      ('supplier_invoice',     'received_to_disputed',      'screen', ''),
      ('supplier_invoice',     'matched_to_disputed',       'screen', ''),
      ('supplier_invoice',     'approved_to_disputed',      'screen', ''),
      ('supplier_invoice',     'disputed_to_matched',       'screen', ''),
      ('supplier_invoice',     'received_to_rejected',      'screen', ''),
      ('supplier_invoice',     'matched_to_rejected',       'screen', ''),
      ('supplier_invoice',     'approved_to_rejected',      'screen', '')
    ) as x(machine_code, transition_code, driver, detail)
$$;

comment on function erp.transition_driver_register() is
  'What fires each transition of every document lifecycle this repository '
  'ships: a button the document page draws (screen), a door or mechanism named '
  'by signature (routine), or a written-down allowance with its reason '
  '(undriven). Read by erp.undriven_transition_report(); mirrored in '
  'DOOR_ONLY_TRANSITIONS, which src/lib/stage-records.test.ts holds to it. '
  'Restated at 20260922360000 and 20260922380000.';

do $u5$
declare
  v_def text := pg_get_functiondef('erp.undriven_transition_report(jsonb)'::regprocedure);
  v_old constant text := $o$     and not exists (select 1 from declared d
                      where d.machine_code = r.machine_code
                        and d.transition_code = r.transition_code)
$o$;
  v_new constant text := $n$     and not exists (select 1 from declared d
                      where d.machine_code = r.machine_code
                        and d.transition_code = r.transition_code)
     -- Nor one the upgrade this release ships declares, before any
     -- organisation has promoted it (20260922380000): the installer's
     -- CURRENT version only, so every later version must restate the
     -- machine with the code, and a code only an older payload declared is
     -- reported as before.
     and not exists (
       select 1
         from erp_ref.module_installer mi
         join erp_ref.module_upgrade_item ui
           on ui.install_code = mi.install_code
          and ui.to_version = mi.current_version
          and ui.object_kind = 'state_machine'
          and ui.object_key = r.machine_code
        where ui.payload ->> 'code' = r.machine_code
          and coalesce(ui.payload ->> 'object_type', 'document') = 'document'
          and jsonb_typeof(ui.payload -> 'transitions') = 'array'
          and ui.payload -> 'transitions'
                @> jsonb_build_array(jsonb_build_object('code', r.transition_code)))
$n$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.undriven_transition_report finding 5 anchor found % time(s)',
      (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  end if;
  execute replace(v_def, v_old, v_new);
end $u5$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A6. The words
--
-- The three refusals this migration raises, registered. An order is issued
-- to its supplier in version 2, so the words that said "sent" say "issued".
-- 20260922370000 registered M1's three refusals; they are left alone.
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_APPROVAL_NOT_CARRIED',
  'Approving a purchase order as the requisition it came from, other than by the conversion that raised it.',
  'An order is approved with its requisition only as it is converted from it, unchanged and to the supplier and site the requisition named. Pressed later, the move would approve an order nobody looked at, including one an approver has refused.',
  'Submit the order for its own approval.');
select erp.register_refusal('CLOVEERP_CARRIED_ORDER_CHANGED',
  'Issuing a purchase order approved with its requisition after its lines or its value were changed.',
  'Nobody but the requisition''s approver looked at an order approved with it. Changed and then issued, it would commit the organisation to something nobody approved.',
  'Put the order back as it was converted, or have an approver cancel it and raise it again for its own approval.');
select erp.register_refusal('CLOVEERP_BILL_FROM_ANOTHER_SUPPLIER',
  'Invoicing a purchase order''s line on a document that is not a bill from the order''s own supplier.',
  'An order closes itself once its goods are billed. A bill from somebody else, or something that is not a bill, would close it with nothing owed to the supplier who sent the goods.',
  'Invoice the order on a bill from its own supplier.');
select erp.register_refusal('CLOVEERP_ORDER_NOT_SENT',
  'Receiving goods against a purchase order that has not been issued to the supplier, or has already been received in full.',
  'An order commits the organisation when it is issued to the supplier. A draft, an order waiting on its approval, or one approved and never issued has promised nothing, so there is nothing to receive against.',
  'Have the order approved and issue it to the supplier, then receive against it. Goods beyond an order received in full need an order of their own.');
select erp.register_refusal('CLOVEERP_NOT_A_PURCHASE_ORDER',
  (select r.refused from erp_ref.refusal r where r.code = 'CLOVEERP_NOT_A_PURCHASE_ORDER'),
  (select r.why from erp_ref.refusal r where r.code = 'CLOVEERP_NOT_A_PURCHASE_ORDER'),
  'Choose a purchase order that has been issued to the supplier.');

-- The raised texts follow the registered words.
do $issued$
declare
  v_sig text;
  v_def text;
  p     record;
  v_hits integer;
begin
  for p in
    select * from (values
      ('erp.create_receipt_from_order(uuid,jsonb,text)',
       'Choose the purchase order from the list of orders sent to a supplier.',
       'Choose the purchase order from the list of orders issued to a supplier.', 1),
      ('erp.create_receipt_from_order(uuid,jsonb,text)',
       'Choose a purchase order that has been sent to the supplier.',
       'Choose a purchase order that has been issued to the supplier.', 1),
      ('erp.create_receipt_from_order(uuid,jsonb,text)',
       'goods are received only against an order sent to the supplier',
       'goods are received only against an order issued to the supplier', 1),
      ('erp.create_receipt_from_order(uuid,jsonb,text)',
       'Have the order approved and send it to the supplier first.',
       'Have the order approved and issue it to the supplier first.', 1),
      ('erp.receive_against(uuid,uuid,numeric,uuid)',
       'goods are received only against an order sent to the supplier',
       'goods are received only against an order issued to the supplier', 1),
      ('erp.receive_against(uuid,uuid,numeric,uuid)',
       'Have the order approved and send it to the supplier first.',
       'Have the order approved and issue it to the supplier first.', 1)
    ) as x(sig, old, new, expected)
  loop
    v_def := pg_get_functiondef(p.sig::regprocedure);
    v_hits := (length(v_def) - length(replace(v_def, p.old, ''))) / length(p.old);
    if v_hits <> p.expected then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % holds "%" % time(s), expected %', p.sig, p.old, v_hits, p.expected;
    end if;
    execute replace(v_def, p.old, p.new);
  end loop;
end
$issued$;

do $words$
declare
  v_n integer;
begin
  update erp_ref.first_run_step
     set why = 'Issued to the supplier; the receipt and the bill match against it.'
   where guide_code = 'procurement' and seq = 2
     and why = 'Sent to the supplier; the receipt and the invoice match against it.';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the procurement guide''s second step changed % row(s), expected 1', v_n;
  end if;

  update erp_ref.help_topic
     set steps = jsonb_set(steps, '{3}', to_jsonb(replace(steps ->> 3, 'Once it is sent', 'Once it is issued')))
   where screen_path = '/inventory/forecast' and steps ->> 3 like '%Once it is sent%';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the forecast help''s fourth step changed % row(s), expected 1', v_n;
  end if;

  update erp_ref.order_behaviour
     set description = replace(description, 'when sent', 'when issued')
   where code = 'standard' and description like '%when sent%';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the standard order behaviour changed % row(s), expected 1', v_n;
  end if;
end
$words$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A8. Version 1, for the suites that stand an organisation up on it
--
-- Derived from the helper with jsonb operations: version 2 less
-- inherit_approval, less requisition_value, less the requisition's chain,
-- with no automatic moves and the words "Sent to supplier". Tests only; a
-- rollback uses the snapshot the upgrade's promotion took.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.procurement_lifecycle_v1_items(
  p_entity_code text, p_threshold_minor bigint default 1000000,
  p_approver_role text default 'administrator')
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_agg(
    case
      when x.item ->> 'kind' = 'state_machine' and x.item ->> 'key' in ('requisition', 'purchase_order') then
        jsonb_set(jsonb_set(x.item, '{payload,transitions}',
          (select jsonb_agg(case when t.tr ->> 'code' = 'send'
                                 then (t.tr - 'is_automatic') || jsonb_build_object('name', 'Send to supplier')
                                 else t.tr - 'is_automatic' end order by t.o)
             from jsonb_array_elements(x.item -> 'payload' -> 'transitions') with ordinality t(tr, o)
            where t.tr ->> 'code' <> 'inherit_approval')),
          '{payload,states}',
          (select jsonb_agg(case when s.st ->> 'code' = 'sent'
                                 then s.st || jsonb_build_object('name', 'Sent to supplier') else s.st end order by s.o)
             from jsonb_array_elements(x.item -> 'payload' -> 'states') with ordinality s(st, o)))
      when x.item ->> 'kind' = 'document_type' and x.item ->> 'key' = 'requisition'
        then x.item #- '{payload,approval_chain}'
      else x.item end
    order by x.n)
  from jsonb_array_elements(erp.procurement_lifecycle_items(p_entity_code, p_threshold_minor, p_approver_role))
       with ordinality x(item, n)
  where not (x.item ->> 'kind' = 'approval_chain' and x.item ->> 'key' = 'requisition_value')
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A7. The suites version 2 changes the answer for
--
-- approval_hold_suite pinned that a requisition, whose type named no chain,
-- was approved on the permission alone. In version 2 it asks for the value
-- approval an order asks for, and waits for it like one. That the type with no
-- chain still approves on its permission is now the reseed suite's first
-- case, on an organisation standing on version 1. Still seventeen cases.
-- ─────────────────────────────────────────────────────────────────────────────

do $hold$
declare
  v_sig constant text := 'erp_test.approval_hold_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a1 constant text := $o$    -- A requisition's type names no chain: approved on the permission alone.
    v_rq := erp.open_document('requisition', v_sup);
    perform erp.add_document_line(v_rq, v_item, 1, 5000, 'One widget');
    perform erp.transition_document(v_rq, 'submit');
    v_rq_state := erp.transition_document(v_rq, 'approve');
    select count(*) into v_rq_requests
      from erp.approval_request q
     where q.tenant_id = r.tenant_id and q.object_id = v_rq;
$o$;
  b1 constant text := $n$    -- A requisition asks for the value approval an order asks for
    -- (20260922380000), and is not approved while it waits.
    v_rq := erp.open_document('requisition', v_sup);
    perform erp.add_document_line(v_rq, v_item, 1, 5000, 'One widget');
    perform erp.transition_document(v_rq, 'submit');
    begin
      v_rq_state := erp.transition_document(v_rq, 'approve');
    exception when others then
      v_rq_state := split_part(sqlerrm, ':', 1);
    end;
    select count(*) into v_rq_requests
      from erp.approval_request q
     where q.tenant_id = r.tenant_id and q.object_id = v_rq and q.status = 'pending';
$n$;
  a2 constant text := $o$  case_name := 'a document type with no approval chain is approved as before, by whoever may';
  passed := coalesce(v_state is null and v_rq_state = 'approved' and v_rq_requests = 0, false);
  detail := coalesce(v_state, format('the requisition moved to %s with %s approval request(s)', v_rq_state, v_rq_requests));
$o$;
  b2 constant text := $n$  case_name := 'a requisition asks for its value approval, and is not approved while it waits';
  passed := coalesce(v_state is null and v_rq_state = 'CLOVEERP_DOCUMENT_APPROVAL_PENDING'
                     and v_rq_requests = 1, false);
  detail := coalesce(v_state, format('pressing approve gave %s with %s pending approval request(s)',
                                     v_rq_state, v_rq_requests));
$n$;
  n integer;
begin
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1),
      (length(v_def) - length(replace(v_def, a2, ''))) / length(a2)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(v_def, a1, b1), a2, b2);
end
$hold$;

-- onward_transition_suite converted an approved requisition, which named its
-- supplier, with `auto`, and pinned an order submitted for approval. In
-- version 2 that order is approved with its requisition, and the conversion
-- never issues it. Still sixteen cases.
do $onward$
declare
  v_sig constant text := 'erp_test.onward_transition_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a1 constant text := $o$  case_name := 'an approved requisition converted with move-on raises a purchase order submitted for approval, not a cancelled one';
  passed := coalesce(v_state is null and v_made_err is null and v_conv_err is null
                     and v_conv ->> 'moved_on' = 'submit'
                     and v_conv_state = 'pending_approval'
$o$;
  b1 constant text := $n$  case_name := 'an approved requisition converted with move-on raises a purchase order approved with it and not issued, not a cancelled one';
  passed := coalesce(v_state is null and v_made_err is null and v_conv_err is null
                     and v_conv ->> 'moved_on' = 'inherit_approval'
                     and v_conv_state = 'approved'
$n$;
  n integer;
begin
  n := (length(v_def) - length(replace(v_def, a1, ''))) / length(a1);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, a1, b1);
end
$onward$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A7. What proves it
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.derived_authority_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid; v_admin uuid; v_token text;
  v_auth   uuid := gen_random_uuid();
  v_entity uuid; v_site uuid; v_north uuid; v_uom uuid; v_sup uuid; v_cus uuid; v_item uuid;
  -- The people, each holding one role: who they are to the database (auth)
  -- and to the organisation (app_user).
  a_wh uuid := gen_random_uuid(); u_wh uuid;   -- warehouse: receives, may not order
  a_ap uuid := gen_random_uuid(); u_ap uuid;   -- matches bills, may not order
  a_bn uuid := gen_random_uuid(); u_bn uuid;   -- purchasing, at the north site only
  a_sn uuid := gen_random_uuid(); u_sn uuid;   -- sales, at the north site only
  a_fn uuid := gen_random_uuid(); u_fn uuid;   -- finance, no procurement at all
  v_role uuid; v_uid uuid;
  v_po1 uuid; v_po uuid; v_pl uuid; v_g uuid; v_bill uuid;
  v_req uuid; v_q uuid; v_so uuid; v_dr uuid; v_ap uuid; v_svc uuid; v_u uuid;
  r jsonb; v_ok boolean; v_msg text; v_st text; v_log erp.state_transition_log%rowtype;
  x record;
  v_sup2 uuid; v_po2 uuid; v_pl2 uuid; v_bl uuid; v_smv1 uuid; v_smv2 uuid; v_status text; v_n integer;
  v_si uuid; v_sil uuid; v_sol uuid; v_rel numeric;
begin
  begin
    select p.tenant_id, p.admin_user_id, p.admin_token into v_tenant, v_admin, v_token
      from erp.provision_tenant('zzdau', 'Derived Authority Suite', 'admin@zzdau.test', 'Authority Admin') p;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (v_auth, 'admin@zzdau.test');
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    perform erp.claim_invitation(v_token);
    perform erp.ensure_demo_configuration(v_tenant, v_admin);

    select e.id into v_entity from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = v_tenant and s.entity_id = v_entity order by s.code limit 1;
    if v_site is null then
      insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
      values (v_tenant, v_entity, 'ZMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    end if;
    if not exists (select 1 from erp.location l where l.tenant_id = v_tenant and l.site_id = v_site
                     and l.location_type = 'receiving' and l.status = 'active') then
      insert into erp.location (tenant_id, site_id, code, name, location_type, status)
      values (v_tenant, v_site, 'ZRECV', 'Receiving', 'receiving', 'active');
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (v_tenant, v_entity, 'ZNORTH', 'North', 'warehouse', 'active') returning id into v_north;
    select u.id into v_uom from erp.uom u where u.tenant_id = v_tenant order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (v_tenant, 'ZEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.party (tenant_id, code, name, status)
    values (v_tenant, 'ZSUP', 'Authority Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (v_tenant, v_sup, 'supplier', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (v_tenant, 'ZSUP2', 'Authority Suite Other Supplier', 'active') returning id into v_sup2;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (v_tenant, v_sup2, 'supplier', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (v_tenant, 'ZCUS', 'Authority Suite Customer', 'active') returning id into v_cus;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (v_tenant, v_cus, 'customer', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, net_weight_g, status)
    values (v_tenant, 'ZWID', 'Authority Suite Widget', v_uom, 100, 'active') returning id into v_item;

    -- An accounts-payable role: bills, and nothing that orders.
    insert into erp.role (tenant_id, code, name)
    values (v_tenant, 'zz_payables', 'Payables') returning id into v_role;
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    values (v_tenant, v_role, 'procurement.match'), (v_tenant, v_role, 'procurement.read');

    insert into auth.users (id, email) values
      (a_wh, 'wh@zzdau.test'), (a_ap, 'ap@zzdau.test'), (a_bn, 'bn@zzdau.test'),
      (a_sn, 'sn@zzdau.test'), (a_fn, 'fn@zzdau.test');
    for x in select * from (values
        (a_wh, 'wh@zzdau.test', 'Warehouse Person', 'warehouse',   null::uuid),
        (a_ap, 'ap@zzdau.test', 'Payables Person',  'zz_payables', null::uuid),
        (a_bn, 'bn@zzdau.test', 'North Buyer',      'purchasing',  v_north),
        (a_sn, 'sn@zzdau.test', 'North Seller',     'sales',       v_north),
        (a_fn, 'fn@zzdau.test', 'Finance Person',   'finance',     null::uuid)) p(auth_id, email, name, role_code, site_id)
    loop
      perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
      select i.app_user_id, i.token into v_uid, v_token from erp.invite_principal(x.email, x.name) i;
      perform erp.grant_role(v_uid, x.role_code,
                             case when x.site_id is null then null else v_entity end, x.site_id,
                             'the derived authority suite', null, null, null);
      perform set_config('request.jwt.claims', json_build_object('sub', x.auth_id)::text, true);
      perform erp.claim_invitation(v_token);
      case x.auth_id
        when a_wh then u_wh := v_uid; when a_ap then u_ap := v_uid; when a_bn then u_bn := v_uid;
        when a_sn then u_sn := v_uid; else u_fn := v_uid;
      end case;
    end loop;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    -- 1. Billed before the goods came; the receipt posted by somebody who may
    --    not close orders (M1's review, m1rev/v3_wh.sql).
    v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pl := erp.add_document_line(v_po, v_item, 10, 1000, 'ten');
    perform erp.transition_document(v_po, 'submit', null);
    perform erp_test.approve_document(v_po, null);
    perform erp.transition_document(v_po, 'send', null);
    v_bill := erp.open_document('purchase_invoice', v_sup, v_entity, v_site);
    perform erp.invoice_against(v_bill, v_pl, 10, 1000);
    update erp.document set their_reference = 'ZDAU-1', due_date = current_date + 30
     where tenant_id = v_tenant and id = v_bill;
    perform erp.transition_document(v_bill, 'register', null);
    v_g := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_g, v_pl, 10, null);
    perform set_config('request.jwt.claims', json_build_object('sub', a_wh)::text, true);
    perform erp.transition_document(v_g, 'post', null);
    select l.* into v_log from erp.state_transition_log l
     where l.tenant_id = v_tenant and l.object_type = 'document' and l.object_id = v_po
       and l.transition_code = 'close' order by l.id desc limit 1;
    return query select 'goods for an order billed first close it, though whoever posted them may not close orders',
      erp.object_current_state('document', v_po) = 'closed'
      and v_log.actor_id = u_wh
      and v_log.guard_data -> 'derived' ->> 'fact' = 'erp.order_is_settled'
      and (v_log.guard_data -> 'derived' ->> 'actor_permitted')::boolean is false
      and exists (select 1 from erp.access_log a
                   where a.tenant_id = v_tenant and a.object_id = v_po and a.app_user_id = u_wh
                     and a.permission_code = 'procurement.order' and a.granted
                     and a.reason like 'derived from %order_is_settled%')
      and not exists (select 1 from erp.event ev
                       where ev.tenant_id = v_tenant and ev.aggregate_id = v_po
                         and ev.event_type = 'document.progress_not_advanced'),
      format('%s, by %s, derived %s', erp.object_current_state('document', v_po),
             coalesce(v_log.actor_id::text, 'nobody'), coalesce((v_log.guard_data -> 'derived')::text, 'no'));
    v_po1 := v_po;

    -- 2. Received first; the bill registered by somebody who may match bills
    --    and not order (the limitation 20260922370000 left to the owner).
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pl := erp.add_document_line(v_po, v_item, 10, 1000, 'ten');
    perform erp.transition_document(v_po, 'submit', null);
    perform erp_test.approve_document(v_po, null);
    perform erp.transition_document(v_po, 'send', null);
    v_g := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_g, v_pl, 10, null);
    perform erp.transition_document(v_g, 'post', null);
    perform set_config('request.jwt.claims', json_build_object('sub', a_ap)::text, true);
    v_bill := erp.open_document('purchase_invoice', v_sup, v_entity, v_site);
    perform erp.invoice_against(v_bill, v_pl, 10, 1000);
    update erp.document set their_reference = 'ZDAU-2', due_date = current_date + 30
     where tenant_id = v_tenant and id = v_bill;
    v_st := erp.transition_document(v_bill, 'register', null);
    select l.* into v_log from erp.state_transition_log l
     where l.tenant_id = v_tenant and l.object_type = 'document' and l.object_id = v_po
       and l.transition_code = 'close' order by l.id desc limit 1;
    return query select 'the bill that settles a received order closes it, though whoever registered it may not close orders',
      v_st = 'registered'
      and erp.object_current_state('document', v_po) = 'closed'
      and v_log.actor_id = u_ap
      and v_log.reason like 'Billed in full by %'
      and v_log.guard_data -> 'derived' ->> 'fact' = 'erp.order_is_settled',
      format('bill %s, order %s, by %s', v_st, erp.object_current_state('document', v_po),
             coalesce(v_log.actor_id::text, 'nobody'));

    -- 3. A buyer who may order only at another site converts all of a
    --    requisition (M1's review, m1rev/t3_scoped.sql).
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    v_req := erp.open_document('requisition', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_req, v_item, 5, 1000, 'five');
    perform erp.transition_document(v_req, 'submit', null);
    perform erp.approve_my_document_tasks(v_req, 'the derived authority suite');
    if erp.object_current_state('document', v_req) = 'submitted' then
      perform erp.transition_document(v_req, 'approve', null);
    end if;
    perform set_config('request.jwt.claims', json_build_object('sub', a_bn)::text, true);
    v_ok := erp.has_permission('procurement.order', v_entity, v_site);
    r := public.erp_convert_document(v_req, null, v_north, null, null);
    select l.* into v_log from erp.state_transition_log l
     where l.tenant_id = v_tenant and l.object_type = 'document' and l.object_id = v_req
       and l.transition_code = 'order' order by l.id desc limit 1;
    return query select 'a requisition converted in full by a buyer from another site reads ordered',
      not v_ok
      and r ->> 'source_moved_on' = 'order'
      and erp.object_current_state('document', v_req) = 'ordered'
      and v_log.actor_id = u_bn
      and v_log.guard_data -> 'derived' ->> 'fact' = 'erp.document_is_fully_converted'
      and coalesce(current_setting('erp.deriving_move', true), '') = '',
      format('buyer may order at its site: %s; %s; requisition %s', v_ok, r - 'document_id',
             erp.object_current_state('document', v_req));

    -- 4. The same conversion of a quotation leaves it sent: its acceptance is
    --    the customer's news, and still a person's to record.
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    v_q := erp.open_document('quotation', v_cus, v_entity, v_site);
    perform erp.add_document_line(v_q, v_item, 2, 3000, 'two');
    perform erp.transition_document(v_q, 'send', null);
    perform set_config('request.jwt.claims', json_build_object('sub', a_sn)::text, true);
    r := public.erp_convert_document(v_q, null, v_north, null, null);
    return query select 'a quotation converted by a seller from another site is not accepted on their behalf',
      r ->> 'source_moved_on' is null and erp.object_current_state('document', v_q) = 'sent',
      format('source moved on %s, quotation %s', coalesce(r ->> 'source_moved_on', 'nothing'),
             erp.object_current_state('document', v_q));

    -- 5. A close by hand stays the person's: their permission with a reason,
    --    the fact without one.
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    v_u := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pl := erp.add_document_line(v_u, v_item, 10, 1000, 'ten');
    perform erp.transition_document(v_u, 'submit', null);
    perform erp_test.approve_document(v_u, null);
    perform erp.transition_document(v_u, 'send', null);
    v_g := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_g, v_pl, 10, null);
    perform erp.transition_document(v_g, 'post', null);
    perform set_config('request.jwt.claims', json_build_object('sub', a_wh)::text, true);
    v_ok := true; v_msg := '';
    begin
      perform erp.transition_document(v_u, 'close', 'Billed on the old system');
      v_ok := false; v_msg := 'a person who may not close orders closed one with a reason';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PERMISSION_DENIED: procurement.order%';
      v_msg := left(sqlerrm, 90);
    end;
    begin
      perform erp.transition_document(v_u, 'close', null);
      v_ok := false; v_msg := 'an order was closed by hand with nothing billed';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_ORDER_NOT_SETTLED:%';
    end;
    return query select 'a close by hand asks for the person''s permission with a reason, and for the fact without one',
      v_ok and erp.object_current_state('document', v_u) = 'received', v_msg;

    -- 6. The marker named by hand on that order, which nothing has billed,
    --    grants nothing: the fact is read, not the marker.
    perform set_config('erp.deriving_move', v_u::text || ':close', true);
    v_ok := erp.derived_move_fact('document', v_u, 'close') is null;
    begin
      perform erp.transition_document(v_u, 'close', 'I say it is billed');
      v_ok := false; v_msg := 'the marker closed an order nothing has billed';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_PERMISSION_DENIED: procurement.order%';
      v_msg := left(sqlerrm, 90);
    end;
    begin
      perform erp.transition_document(v_u, 'close', null);
      v_ok := false; v_msg := 'the marker closed an order nothing has billed, with no reason';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_ORDER_NOT_SETTLED:%';
    end;
    perform set_config('erp.deriving_move', '', true);
    return query select 'the marker named by hand on an order nothing has billed closes nothing',
      v_ok and erp.object_current_state('document', v_u) = 'received', v_msg;

    -- 7. Named by hand for any other move, it grants nothing either.
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    v_dr := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_dr, v_item, 3, 1000, 'three');
    v_ap := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_ap, v_item, 3, 1000, 'three');
    perform erp.transition_document(v_ap, 'submit', null);
    perform erp_test.approve_document(v_ap, null);
    v_svc := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_svc, null, 1, 50000, 'Annual calibration visit');
    perform erp.transition_document(v_svc, 'submit', null);
    if erp.object_current_state('document', v_svc) = 'pending_approval' then
      perform erp_test.approve_document(v_svc, null);
    end if;
    perform erp.transition_document(v_svc, 'send', null);
    v_so := erp.open_document('sales_order', v_cus, v_entity, v_site);
    perform erp.add_document_line(v_so, v_item, 1, 3000, 'one');
    v_ok := true; v_msg := '';
    for x in select * from (values
        (a_wh, v_dr,  'cancel',      null::text),
        (a_wh, v_dr,  'submit',      null::text),
        (a_wh, v_ap,  'send',        null::text),
        (a_fn, v_svc, 'receive_all', 'The visit happened on the day'),
        (a_wh, v_q,   'accept',      null::text)) m(who, doc, code, why)
    loop
      perform set_config('request.jwt.claims', json_build_object('sub', x.who)::text, true);
      perform set_config('erp.deriving_move', x.doc::text || ':' || x.code, true);
      begin
        perform erp.transition_document(x.doc, x.code, x.why);
        v_ok := false; v_msg := v_msg || x.code || ' was made; ';
      exception when others then
        if sqlerrm not like 'CLOVEERP_PERMISSION_DENIED:%' then
          v_ok := false; v_msg := v_msg || x.code || ': ' || left(sqlerrm, 60) || '; ';
        end if;
      end;
    end loop;
    perform set_config('erp.deriving_move', v_so::text || ':close', true);
    v_ok := v_ok and erp.derived_move_fact('document', v_so, 'close') is null;
    perform set_config('erp.deriving_move', '', true);
    return query select 'the marker named by hand for another move, or a sales document, grants nothing',
      v_ok, coalesce(nullif(v_msg, ''), 'cancel, submit, send, receive_all and accept refused; a sales order''s close is no fact');

    -- 8. It is bound to one document and one move, and to the state the move
    --    leaves from. The requisition of case 3 is fully converted and the
    --    order of case 1 is settled, so only the binding can say no.
    perform set_config('request.jwt.claims', json_build_object('sub', a_wh)::text, true);
    perform set_config('erp.deriving_move', v_req::text || ':order', true);
    v_ok := erp.derived_move_fact('document', v_req, 'order') = 'erp.document_is_fully_converted'
        and erp.derived_move_fact('document', v_req, 'cancel') is null
        and erp.derived_move_fact('requisition', v_req, 'order') is null;
    perform set_config('erp.deriving_move', v_u::text || ':order', true);
    v_ok := v_ok and erp.derived_move_fact('document', v_req, 'order') is null;
    perform set_config('erp.deriving_move', v_po1::text || ':close', true);
    v_ok := v_ok and erp.order_is_settled(v_po1)
        and erp.derived_move_fact('document', v_po1, 'close') is null;
    perform set_config('erp.deriving_move', '', true);
    return query select 'the marker is bound to its document, its move and the state the move leaves from',
      v_ok, 'another document, another move, another object type and a settled order already closed all read null';

    -- 9. With M2's carried approval: one conversion, two moves, two markers.
    --    The order's inherit_approval is an approval and keeps its permission
    --    (it is not derived); the requisition's order is derived. Neither
    --    marker outlives the conversion.
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    v_req := erp.open_document('requisition', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_req, v_item, 4, 1000, 'four');
    perform erp.transition_document(v_req, 'submit', null);
    perform erp.approve_my_document_tasks(v_req, 'the derived authority suite');
    if erp.object_current_state('document', v_req) = 'submitted' then
      perform erp.transition_document(v_req, 'approve', null);
    end if;
    r := public.erp_convert_document(v_req, null, null, null, null);
    v_po := (r ->> 'document_id')::uuid;
    return query select 'a conversion that carries the approval asks the approval''s permission and derives only the requisition''s move',
      erp.object_current_state('document', v_po) = 'approved'
      and exists (select 1 from erp.state_transition_log l
                   where l.tenant_id = v_tenant and l.object_id = v_po
                     and l.transition_code = 'inherit_approval' and l.guard_data -> 'derived' is null)
      and erp.object_current_state('document', v_req) = 'ordered'
      and exists (select 1 from erp.state_transition_log l
                   where l.tenant_id = v_tenant and l.object_id = v_req and l.transition_code = 'order'
                     and l.guard_data -> 'derived' ->> 'fact' = 'erp.document_is_fully_converted'
                     and (l.guard_data -> 'derived' ->> 'actor_permitted')::boolean)
      and coalesce(current_setting('erp.carrying_approval', true), '') = ''
      and coalesce(current_setting('erp.deriving_move', true), '') = '',
      format('order %s (%s), requisition %s', erp.object_current_state('document', v_po),
             coalesce(r ->> 'approval_not_carried', 'carried'), erp.object_current_state('document', v_req));

    -- 10. The bill the close's fact reads cannot be written after it has
    --     posted (attack 1, X1): a line added to a registered bill would
    --     settle an order with nothing owed for it.
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pl := erp.add_document_line(v_po, v_item, 10, 1000, 'ten');
    perform erp.transition_document(v_po, 'submit', null);
    perform erp_test.approve_document(v_po, null);
    perform erp.transition_document(v_po, 'send', null);
    v_g := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_g, v_pl, 10, null);
    perform erp.transition_document(v_g, 'post', null);
    v_bill := erp.open_document('purchase_invoice', v_sup, v_entity, v_site);
    perform erp.invoice_against(v_bill, v_pl, 10, 1000);
    update erp.document set their_reference = 'ZDAU-10', due_date = current_date + 30
     where tenant_id = v_tenant and id = v_bill;
    perform erp.transition_document(v_bill, 'register', null);
    v_po2 := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pl2 := erp.add_document_line(v_po2, v_item, 10, 1000, 'ten more');
    perform erp.transition_document(v_po2, 'submit', null);
    perform erp_test.approve_document(v_po2, null);
    perform erp.transition_document(v_po2, 'send', null);
    v_g := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_g, v_pl2, 10, null);
    perform erp.transition_document(v_g, 'post', null);
    perform set_config('request.jwt.claims', json_build_object('sub', a_ap)::text, true);
    begin
      perform erp.invoice_against(v_bill, v_pl2, 10, 1000);
      v_ok := false; v_msg := 'a line was added to a registered bill';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PAST_AMENDMENT_CUT_OFF: ledger_posted%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a line added to a bill that has posted is refused, and the order it would have settled stays received',
      v_ok and erp.object_current_state('document', v_po2) = 'received' and not erp.order_is_settled(v_po2), v_msg;

    -- 11. A matched bill line changed before the bill is registered takes its
    --     relation with it and is matched again (attack 1, Y1).
    v_bill := erp.open_document('purchase_invoice', v_sup, v_entity, v_site);
    perform erp.invoice_against(v_bill, v_pl2, 10, 1000);
    select dl.id into v_bl from erp.document_line dl
     where dl.tenant_id = v_tenant and dl.document_id = v_bill order by dl.line_no limit 1;
    perform erp.amend_document_line(v_bl, 1, 'the paper says one');
    update erp.document set their_reference = 'ZDAU-11', due_date = current_date + 30
     where tenant_id = v_tenant and id = v_bill;
    v_st := erp.transition_document(v_bill, 'register', null);
    return query select 'a matched bill line changed before it is registered takes its match with it, and settles nothing',
      (select r.quantity from erp.document_relation r
        where r.tenant_id = v_tenant and r.from_line_id = v_bl and r.relation_kind = 'invoices') = 1
      and v_st = 'disputed'
      and erp.object_current_state('document', v_po2) = 'received' and not erp.order_is_settled(v_po2),
      format('relation %s, bill %s, order %s',
             (select r.quantity from erp.document_relation r
               where r.tenant_id = v_tenant and r.from_line_id = v_bl and r.relation_kind = 'invoices'),
             v_st, erp.object_current_state('document', v_po2));

    -- 12. Nor does a bill from another supplier invoice the order (attack 1, Y2).
    v_bill := erp.open_document('purchase_invoice', v_sup2, v_entity, v_site);
    begin
      perform erp.invoice_against(v_bill, v_pl2, 10, 1000);
      v_ok := false; v_msg := 'another supplier''s bill invoiced the order';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BILL_FROM_ANOTHER_SUPPLIER:%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a bill from another supplier does not invoice the order', v_ok, v_msg;

    -- 13. A requisition M1 left approved though every line is on an order is
    --     ordered by converting it again, and only by somebody who may raise
    --     an order (attack 6). Written back to approved directly, because no
    --     door leaves one there now.
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    v_req := erp.open_document('requisition', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_req, v_item, 3, 1000, 'three');
    perform erp.transition_document(v_req, 'submit', null);
    perform erp.approve_my_document_tasks(v_req, 'the derived authority suite');
    if erp.object_current_state('document', v_req) = 'submitted' then
      perform erp.transition_document(v_req, 'approve', null);
    end if;
    perform erp.convert_document(v_req, null, v_site);
    update erp.object_state os
       set current_state_id = (select s.id from erp.state s
                                where s.state_machine_version_id = os.state_machine_version_id
                                  and s.code = 'approved')
     where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = v_req;
    perform set_config('request.jwt.claims', json_build_object('sub', a_wh)::text, true);
    begin
      r := public.erp_convert_document(v_req, null, null, null, null);
      v_ok := false; v_msg := 'somebody who may not order converted it';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PERMISSION_DENIED:%'; v_msg := left(sqlerrm, 90);
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a_bn)::text, true);
    r := public.erp_convert_document(v_req, null, v_north, null, null);
    select count(*) into v_n from erp.document_relation rel
     where rel.tenant_id = v_tenant and rel.to_document_id = v_req and rel.relation_kind = 'converts';
    return query select 'a requisition left approved with every line ordered is ordered by converting it again',
      v_ok and r ->> 'source_moved_on' = 'order' and r ->> 'document_id' is null and v_n = 1
      and erp.object_current_state('document', v_req) = 'ordered'
      and coalesce(current_setting('erp.deriving_move', true), '') = '',
      format('%s; %s relation(s); requisition %s', coalesce(nullif(v_msg, ''), '-'), v_n,
             erp.object_current_state('document', v_req));

    -- 14. A derived move is still refused by everything erp.authorise() asks
    --     before the permission (attack 3): in a restricted organisation the
    --     close is refused for the organisation and recorded.
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    update erp.object_state os
       set current_state_id = (select s.id from erp.state s
                                where s.state_machine_version_id = os.state_machine_version_id
                                  and s.code = 'received')
     where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = v_po1;
    select t.status::text into v_status from erp.tenant t where t.id = v_tenant;
    update erp.tenant set status = 'restricted' where id = v_tenant;
    perform set_config('request.jwt.claims', json_build_object('sub', a_wh)::text, true);
    v_ok := not erp.close_order_when_settled(v_po1, 'Billed in full');
    update erp.tenant set status = v_status::erp.tenant_status where id = v_tenant;
    return query select 'a derived close in a restricted organisation is refused for the organisation, and recorded',
      v_ok and erp.order_is_settled(v_po1)
      and erp.object_current_state('document', v_po1) = 'received'
      and exists (select 1 from erp.event ev
                   where ev.tenant_id = v_tenant and ev.aggregate_id = v_po1
                     and ev.event_type = 'document.progress_not_advanced'
                     and ev.payload ->> 'reason' like 'CLOVEERP_ORGANISATION_RESTRICTED%')
      and coalesce(current_setting('erp.deriving_move', true), '') = '',
      erp.object_current_state('document', v_po1);

    -- 15. An organisation that puts its own permission on close (decision 8):
    --     the derived close still comes from the fact, and the close by hand
    --     asks for that permission. A new version of the order's lifecycle,
    --     identical but for close's permission.
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    select smv.id into v_smv1
      from erp.state_machine_version smv
      join erp.state_machine sm on sm.id = smv.state_machine_id
     where sm.tenant_id = v_tenant and sm.code = 'purchase_order' and smv.status = 'active';
    insert into erp.state_machine_version (tenant_id, state_machine_id, version, status, effective_from, note)
    select smv.tenant_id, smv.state_machine_id,
           (select max(v2.version) + 1 from erp.state_machine_version v2 where v2.state_machine_id = smv.state_machine_id),
           'draft', current_date, 'the derived authority suite'
      from erp.state_machine_version smv where smv.id = v_smv1
    returning id into v_smv2;
    insert into erp.state (tenant_id, state_machine_version_id, code, name_key, name, description,
                           is_initial, is_terminal, is_committed, sort_order, on_enter, on_exit)
    select s.tenant_id, v_smv2, s.code, s.name_key, s.name, s.description,
           s.is_initial, s.is_terminal, s.is_committed, s.sort_order, s.on_enter, s.on_exit
      from erp.state s where s.state_machine_version_id = v_smv1;
    insert into erp.transition (tenant_id, state_machine_version_id, code, name_key, name, description,
                                from_state_id, to_state_id, guard, required_permission, effects,
                                is_automatic, sort_order)
    select t.tenant_id, v_smv2, t.code, t.name_key, t.name, t.description, f2.id, t2.id, t.guard,
           case when t.code = 'close' then 'finance.post' else t.required_permission end,
           t.effects, t.is_automatic, t.sort_order
      from erp.transition t
      join erp.state f on f.id = t.from_state_id
      join erp.state tt on tt.id = t.to_state_id
      join erp.state f2 on f2.state_machine_version_id = v_smv2 and f2.code = f.code
      join erp.state t2 on t2.state_machine_version_id = v_smv2 and t2.code = tt.code
     where t.state_machine_version_id = v_smv1;
    perform erp.activate_state_machine_version(v_smv2, current_date);
    v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pl := erp.add_document_line(v_po, v_item, 10, 1000, 'ten');
    perform erp.transition_document(v_po, 'submit', null);
    if erp.object_current_state('document', v_po) = 'pending_approval' then
      perform erp_test.approve_document(v_po, null);
    end if;
    perform erp.transition_document(v_po, 'send', null);
    v_bill := erp.open_document('purchase_invoice', v_sup, v_entity, v_site);
    perform erp.invoice_against(v_bill, v_pl, 10, 1000);
    update erp.document set their_reference = 'ZDAU-15', due_date = current_date + 30
     where tenant_id = v_tenant and id = v_bill;
    perform erp.transition_document(v_bill, 'register', null);
    v_g := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_g, v_pl, 10, null);
    v_u := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pl2 := erp.add_document_line(v_u, v_item, 10, 1000, 'ten');
    perform erp.transition_document(v_u, 'submit', null);
    if erp.object_current_state('document', v_u) = 'pending_approval' then
      perform erp_test.approve_document(v_u, null);
    end if;
    perform erp.transition_document(v_u, 'send', null);
    perform set_config('request.jwt.claims', json_build_object('sub', a_wh)::text, true);
    perform erp.transition_document(v_g, 'post', null);
    v_g := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_g, v_pl2, 10, null);
    perform erp.transition_document(v_g, 'post', null);
    select l.* into v_log from erp.state_transition_log l
     where l.tenant_id = v_tenant and l.object_type = 'document' and l.object_id = v_po
       and l.transition_code = 'close' order by l.id desc limit 1;
    v_ok := true; v_msg := '';
    begin
      perform erp.transition_document(v_u, 'close', 'Billed on the old system');
      v_ok := false; v_msg := 'the warehouse closed an order by hand';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PERMISSION_DENIED: finance.post%'; v_msg := left(sqlerrm, 90);
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a_fn)::text, true);
    v_st := erp.transition_document(v_u, 'close', 'Billed on the old system');
    return query select 'an organisation''s own permission on close governs the close by hand, not the one the bill derives',
      v_ok and erp.object_current_state('document', v_po) = 'closed'
      and v_log.guard_data -> 'derived' ->> 'permission' = 'finance.post'
      and v_st = 'closed',
      format('derived close %s (%s); %s; finance closes by hand: %s',
             erp.object_current_state('document', v_po), coalesce(v_log.guard_data -> 'derived' ->> 'permission', 'none'),
             coalesce(nullif(v_msg, ''), '-'), v_st);

    -- 16. A bill with a line that takes value off it settles nothing (found on
    --     review): ten received and billed at ten, less nine on a line of its
    --     own, registered by payables. On main the order waited for somebody
    --     who may close; with the derived close it must wait for the fact.
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pl := erp.add_document_line(v_po, v_item, 10, 1000, 'ten');
    perform erp.transition_document(v_po, 'submit', null);
    if erp.object_current_state('document', v_po) = 'pending_approval' then
      perform erp_test.approve_document(v_po, null);
    end if;
    perform erp.transition_document(v_po, 'send', null);
    v_g := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_g, v_pl, 10, null);
    perform set_config('request.jwt.claims', json_build_object('sub', a_wh)::text, true);
    perform erp.transition_document(v_g, 'post', null);
    perform set_config('request.jwt.claims', json_build_object('sub', a_ap)::text, true);
    v_bill := erp.open_document('purchase_invoice', v_sup, v_entity, v_site);
    perform erp.invoice_against(v_bill, v_pl, 10, 1000);
    perform public.erp_add_document_line(v_bill, v_item, -9, 1000, 'offset');
    update erp.document set their_reference = 'ZDAU-16', due_date = current_date + 30
     where tenant_id = v_tenant and id = v_bill;
    v_msg := '';
    begin
      perform public.erp_transition_document(v_bill, 'register', null);
    exception when others then
      v_msg := left(sqlerrm, 90);
    end;
    return query select 'a bill with a line that takes value off it settles nothing, and closes nothing',
      not erp.order_is_settled(v_po) and erp.object_current_state('document', v_po) = 'received',
      format('bill %s (%s); order %s, settled %s', erp.object_current_state('document', v_bill),
             coalesce(nullif(v_msg, ''), 'registered'), erp.object_current_state('document', v_po),
             erp.order_is_settled(v_po));

    -- 17. A sales invoice does not invoice a purchase order (found on review):
    --     the supplier is also a customer, and a sales invoice to them shares
    --     the bill's base type.
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (v_tenant, v_sup, 'customer', 'active') on conflict do nothing;
    v_si := erp.open_document('sales_invoice', v_sup, v_entity, v_site);
    perform set_config('request.jwt.claims', json_build_object('sub', a_ap)::text, true);
    begin
      perform erp.invoice_against(v_si, v_pl, 10, 1000);
      v_ok := false; v_msg := 'a sales invoice invoiced the purchase order';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BILL_FROM_ANOTHER_SUPPLIER:%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a sales invoice to the supplier does not invoice its purchase order',
      v_ok and not exists (select 1 from erp.document_relation rel
                            where rel.tenant_id = v_tenant and rel.from_document_id = v_si),
      v_msg;

    -- 18. Amending a sales invoice's line leaves its own relation alone (found
    --     on review): only a supplier's bill line carries its quantity into
    --     the relation and is matched again.
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    v_so := erp.open_document('sales_order', v_cus, v_entity, v_site);
    v_sol := erp.add_document_line(v_so, v_item, 5, 2000, 'five');
    v_si := erp.open_document('sales_invoice', v_cus, v_entity, v_site);
    v_sil := erp.add_document_line(v_si, v_item, 5, 2000, 'five');
    insert into erp.document_relation (tenant_id, from_document_id, to_document_id, relation_kind,
                                       from_line_id, to_line_id, quantity)
    values (v_tenant, v_si, v_so, 'invoices', v_sil, v_sol, 5);
    perform erp.amend_document_line(v_sil, 2, 'fewer');
    select rel.quantity into v_rel from erp.document_relation rel
     where rel.tenant_id = v_tenant and rel.from_line_id = v_sil;
    return query select 'amending a sales invoice line leaves its relation and matches nothing',
      v_rel = 5 and not exists (select 1 from erp.match_exception mx
                                 where mx.tenant_id = v_tenant and mx.order_line_id = v_sol),
      format('relation quantity %s', v_rel);

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant tn where tn.code = 'zzdau')
            and coalesce(current_setting('erp.deriving_move', true), '') = '';
  detail := 'the organisation, its people and its documents rolled back, and no move named';
  return next;
end;
$$;

comment on function erp_test.derived_authority_suite() is
  'Decision 6 (20260922380000): a move the system derives takes its authority '
  'from the fact, not from whoever triggered it. A received order closes on '
  'its bill whoever posted the goods or registered the bill, a requisition '
  'converted in full reads ordered whoever converted it, and nothing else '
  'moves on the fact: not a quotation, not a close by hand, and not a marker '
  'named by hand.';

create or replace function erp_test.assert_derived_authority_suite()
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
    from erp_test.derived_authority_suite() s;

  if v_total <> 19 then
    raise exception 'CLOVEERP_DERIVED_AUTHORITY_SUITE_SHRANK: % case(s), expected 19', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;

  if v_failed > 0 then
    raise exception 'CLOVEERP_DERIVED_AUTHORITY_SUITE_FAILED: %/% case(s) failed%',
      v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A derived move waiting for somebody who may make it, or made on something that is not so, is the defect this suite exists for. Read the case that failed.';
  end if;
end;
$$;

-- procurement_suite, version 2: the thirteen cases it had, the requisition
-- now approved through its own chain, and twenty-seven on the order approved
-- with its requisition (20260922380000). 13 → 40.

create or replace function erp_test.procurement_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r        record;
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();
  cs_fin   uuid;
  v_cs uuid; v_second uuid; v_tok text; res jsonb;
  v_uom uuid; v_site uuid; v_party uuid; v_item uuid;
  v_req uuid; v_po uuid; v_lo uuid; t record;
  v_ok boolean; v_msg text;
  -- Version 2: an order converted from an approved requisition is born
  -- approved (20260922380000).
  v_site2 uuid; v_party2 uuid; v_item2 uuid; v_item3 uuid; v_box uuid; v_kg uuid;
  v_entity2 uuid; v_req_type uuid;
  v_r1 uuid; v_l1 uuid; v_po1 uuid; v_po2 uuid;
  v_r uuid; v_l uuid; v_a uuid; v_b uuid; v_copy uuid;
  v_po5 uuid; v_po6 uuid;
  v_n integer; v_n2 integer; v_cur text;
  v_ok2 boolean; v_msg2 text; v_why text;
  v_carry jsonb; v_q uuid; v_grn uuid; v_bl uuid; v_co uuid;
  v_ok13 boolean; v_msg13 text;
  v_reason text; v_rows integer; v_fail text;
  res2 jsonb; res3 jsonb;
begin
  select * into r from erp.provision_tenant(
    'zzproc', 'Procurement Suite', 'admin@zzproc.test', 'Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  -- Two-person approval is what this organisation proves (20260914098500).
  perform erp_test.administrator_approval_off(r.tenant_id);

  res := public.erp_invite_principal('second@zzproc.test', 'Second Admin');
  v_second := (res->>'app_user_id')::uuid; v_tok := res->>'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

  -- Procurement reaches a ledger now, so it needs one. The dependency is real
  -- rather than a test artefact: erp.configure_procurement() refuses without it.
  cs_fin := erp.configure_finance();
  v_cs := erp.configure_procurement(1000000);
  return query select 'installing procurement authors a change set, unapproved',
    (select c.status::text from erp.change_set c where c.id = v_cs) = 'ready',
    'B6 will not let its author wave it through';

  begin
    perform erp.approve_change_set(v_cs);
    v_ok := false; v_msg := 'the author approved their own change set';
  exception when sqlstate '42501' then v_ok := true; v_msg := left(sqlerrm, 60); end;
  return query select 'the author of a change set cannot approve it', v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(cs_fin);
  perform erp.promote_change_set(cs_fin);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'promotion installs three lifecycles',
    (select count(*) from erp.state_machine m
      where m.tenant_id = r.tenant_id and m.status = 'active'
        and m.code in ('requisition','purchase_order','goods_receipt')) = 3,
    'requisition, purchase order and goods receipt';

  insert into erp.uom (tenant_id,code,name,uom_class,decimals,is_base,status)
  values (r.tenant_id,'EA','Each','quantity',0,true,'active') returning id into v_uom;
  insert into erp.site (tenant_id,entity_id,code,name,site_type,status)
  values (r.tenant_id,r.entity_id,'MAIN','Main','warehouse','active') returning id into v_site;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'SUP','Supplier','active') returning id into v_party;
  insert into erp.item (tenant_id,code,name,stock_uom_id,status)
  values (r.tenant_id,'WID','Widget',v_uom,'active') returning id into v_item;

  -- Requisition through to its terminal state.
  v_req := erp.open_document('requisition', v_party);
  perform erp.add_document_line(v_req, v_item, 10, 50000, 'Ten widgets');
  return query select 'a document is numbered from its own rule',
    (select d.document_number like 'REQ-%' from erp.document d where d.id = v_req),
    (select d.document_number from erp.document d where d.id = v_req);

  return query select 'the value is derived from the lines, not stored',
    erp.document_value_minor(v_req) = 500000,
    format('%s minor', erp.document_value_minor(v_req));

  perform erp.transition_document(v_req, 'submit');
  -- Version 2 asks for the requisition's approval through its chain, and in a
  -- live organisation whoever asked does not give it: the other administrator
  -- decides the task and approves.
  perform erp_test.approve_document(v_req, 'suite');
  -- By the order raised from it (20260922360000). The bare move is refused.
  -- Converted first and read after, because one SQL expression is free to
  -- read the state before it runs the conversion.
  res := erp.convert_document(v_req, null, v_site);
  return query select 'a requisition reaches its terminal state',
    res ->> 'source_moved_on' = 'order'
    and erp.object_current_state('document', v_req) = 'ordered',
    format('draft to ordered, by the order raised from it (%s)', res ->> 'source_moved_on');

  begin
    perform erp.transition_document(v_req, 'submit');
    v_ok := false; v_msg := 'a transition out of a terminal state was allowed';
  exception when others then v_ok := true; v_msg := left(sqlerrm, 60); end;
  return query select 'a terminal state has no way out', v_ok, v_msg;

  -- The purchase order must run its OWN machine, which is the defect this
  -- module found: start_lifecycle() chose by object_type alone, and every
  -- document type shares object_type 'document'.
  v_po := erp.open_document('purchase_order', v_party, null, v_site);
  perform erp.add_document_line(v_po, v_item, 500, 50000, 'Five hundred');
  return query select 'a document follows the lifecycle its type names',
    (select m.code from erp.object_state os
       join erp.state_machine_version v on v.id = os.state_machine_version_id
       join erp.state_machine m on m.id = v.state_machine_id
      where os.object_id = v_po) = 'purchase_order',
    'not whichever machine shares its object_type';

  perform erp.link_documents(v_req, v_po, 'fulfils');
  return query select 'lineage is navigable in both directions',
    (select count(*) from erp.document_lineage(v_req)) >= 2
    and (select count(*) from erp.document_lineage(v_po)) >= 2,
    'spec 4.5';

  -- The band, measured by status rather than by counting rows.
  perform erp.transition_document(v_po, 'submit');
  -- The second administrator's own task: whoever asks is not asked to approve
  -- (20260914062000), so the step went to the other administrator alone.
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_po and tk.status = 'pending'
              and tk.assignee_user_id = erp.current_principal_id() limit 1
  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'above the threshold, the second approval step opens',
    exists (select 1 from erp.approval_task tk
              join erp.approval_request q on q.id = tk.approval_request_id
             where q.object_id = v_po and tk.step_code = 'finance'
               and tk.status = 'pending'),
    'value 25000000 against a threshold of 1000000';

  v_lo := erp.open_document('purchase_order', v_party, null, v_site);
  perform erp.add_document_line(v_lo, v_item, 1, 500000, 'Small');
  perform erp.transition_document(v_lo, 'submit');
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_lo and tk.status = 'pending'
              and tk.assignee_user_id = erp.current_principal_id() limit 1
  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'below the threshold, it is skipped and recorded as skipped',
    exists (select 1 from erp.approval_task tk
              join erp.approval_request q on q.id = tk.approval_request_id
             where q.object_id = v_lo and tk.step_code = 'finance'
               and tk.status = 'skipped'),
    'omitting it would leave no evidence it was considered';

  -- Committed documents. The large order's finance step is still open, and an
  -- approval holds the document (20260914062000): it is decided, and the order
  -- approved by the second administrator, because the first asked.
  perform erp_test.approve_document(v_po, 'suite');
  perform erp.transition_document(v_po, 'send');
  begin
    perform erp.add_document_line(v_po, v_item, 1, 1, 'sneak');
    v_ok := false; v_msg := 'a committed document accepted a new line';
  exception when sqlstate '42501' then v_ok := true; v_msg := left(sqlerrm, 60); end;
  return query select 'a committed document cannot gain a line', v_ok, v_msg;

  -- Received by its goods (20260922360000). The walk from receipt to bill to
  -- closed is erp_test.derived_order_state_suite()'s.
  begin
    perform erp.transition_document(v_po, 'receive_all');
    v_ok := false; v_msg := 'a sent order was marked received with nothing received';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_ORDER_NOT_RECEIVED:%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a purchase order is received by its goods, not by a button', v_ok, v_msg;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Version 2: the order born approved (20260922380000). Every requisition
  -- below is raised by the first administrator, names its supplier and site,
  -- and is approved by the second, so the approval being carried is somebody
  -- else's judgement (D2, fail closed). A second supplier, a second site in
  -- the same company, a second company, and units to change are what the
  -- refusals need.
  -- ───────────────────────────────────────────────────────────────────────────
  insert into erp.site (tenant_id,entity_id,code,name,site_type,status)
  values (r.tenant_id,r.entity_id,'NORTH','North','warehouse','active') returning id into v_site2;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'SUP2','Other Supplier','active') returning id into v_party2;
  insert into erp.uom (tenant_id,code,name,uom_class,decimals,is_base,status)
  values (r.tenant_id,'BOX','Box of ten','quantity',0,false,'active') returning id into v_box;
  insert into erp.uom (tenant_id,code,name,uom_class,decimals,is_base,status)
  values (r.tenant_id,'KG','Kilogram','mass',3,true,'active') returning id into v_kg;
  insert into erp.item (tenant_id,code,name,stock_uom_id,status)
  values (r.tenant_id,'GAD','Gadget',v_uom,'active') returning id into v_item2;
  insert into erp.item (tenant_id,code,name,stock_uom_id,status)
  values (r.tenant_id,'FLO','Flour',v_kg,'active') returning id into v_item3;
  select dt.id into v_req_type from erp.document_type dt
   where dt.tenant_id = r.tenant_id and dt.code = 'requisition';

  -- 1. The ordinary case: part of the requisition, to the supplier it named.
  v_r1 := erp.open_document('requisition', v_party, null, v_site);
  v_l1 := erp.add_document_line(v_r1, v_item, 10, 1000, 'Ten widgets');
  perform erp.transition_document(v_r1, 'submit');
  perform erp_test.approve_document(v_r1, 'suite');
  select q.id into v_q from erp.approval_request q
   where q.tenant_id = r.tenant_id and q.object_id = v_r1 and q.status = 'approved';
  res := erp.convert_document(v_r1, null, null,
           jsonb_build_array(jsonb_build_object('line_id', v_l1, 'quantity', 4)));
  v_po1 := (res ->> 'document_id')::uuid;
  return query select 'an order converted to the requisition''s supplier is born approved and asks nothing',
    coalesce((res ->> 'born_approved')::boolean, false)
    and erp.object_current_state('document', v_po1) = 'approved'
    and not exists (select 1 from erp.approval_request q
                     where q.tenant_id = r.tenant_id and q.object_id = v_po1)
    and exists (select 1 from erp.state_transition_log l
                 where l.tenant_id = r.tenant_id and l.object_id = v_po1
                   and l.transition_code = 'inherit_approval'
                   and l.reason = 'Approved with ' || (select d.document_number from erp.document d where d.id = v_r1))
    and (select count(*) from erp.event ev
          where ev.tenant_id = r.tenant_id and ev.aggregate_id = v_po1
            and ev.event_type = 'document.approval_carried'
            and ev.payload ->> 'approval_request_id' = v_q::text) = 1
    and coalesce(current_setting('erp.carrying_approval', true), '') = '',
    format('%s %s, own requests %s, log "%s", carried events %s, marker "%s"',
      (select d.document_number from erp.document d where d.id = v_po1),
      erp.object_current_state('document', v_po1),
      (select count(*) from erp.approval_request q where q.tenant_id = r.tenant_id and q.object_id = v_po1),
      (select l.reason from erp.state_transition_log l where l.tenant_id = r.tenant_id
          and l.object_id = v_po1 and l.transition_code = 'inherit_approval'),
      (select count(*) from erp.event ev where ev.tenant_id = r.tenant_id and ev.aggregate_id = v_po1
          and ev.event_type = 'document.approval_carried'),
      coalesce(current_setting('erp.carrying_approval', true), ''));

  -- 2. The rest of it: the family is still within what was approved.
  res := erp.convert_document(v_r1, null, null, null);
  v_po2 := (res ->> 'document_id')::uuid;
  return query select 'the rest of the requisition, converted, is born approved too, and the requisition reads ordered',
    coalesce((res ->> 'born_approved')::boolean, false)
    and erp.object_current_state('document', v_po2) = 'approved'
    and erp.object_current_state('document', v_r1) = 'ordered',
    format('second order %s, requisition %s, not carried: %s',
      erp.object_current_state('document', v_po2), erp.object_current_state('document', v_r1),
      coalesce(res ->> 'approval_not_carried', 'nothing'));

  -- 3. Issuing is the buyer's own act, and so is the commitment it posts.
  v_r := erp.open_document('requisition', v_party, null, v_site);
  v_l := erp.add_document_line(v_r, v_item, 10, 1000, 'Ten widgets');
  perform erp.transition_document(v_r, 'submit');
  perform erp_test.approve_document(v_r, 'suite');
  res := erp.convert_document(v_r, null, null,
           jsonb_build_array(jsonb_build_object('line_id', v_l, 'quantity', 5)), 'auto');
  res2 := erp.convert_document(v_r, null, null, null, 'send');
  return query select 'a conversion never issues: auto or a named send leaves the order approved, with no commitment',
    res ->> 'moved_on' = 'inherit_approval' and res2 ->> 'moved_on' = 'inherit_approval'
    and erp.object_current_state('document', (res ->> 'document_id')::uuid) = 'approved'
    and erp.object_current_state('document', (res2 ->> 'document_id')::uuid) = 'approved'
    and not exists (select 1 from erp.journal j where j.tenant_id = r.tenant_id
                     and j.document_id in ((res ->> 'document_id')::uuid, (res2 ->> 'document_id')::uuid)),
    format('auto: %s (%s), send: %s (%s), commitment journals %s',
      res ->> 'moved_on', erp.object_current_state('document', (res ->> 'document_id')::uuid),
      res2 ->> 'moved_on', erp.object_current_state('document', (res2 ->> 'document_id')::uuid),
      (select count(*) from erp.journal j where j.tenant_id = r.tenant_id
          and j.document_id in ((res ->> 'document_id')::uuid, (res2 ->> 'document_id')::uuid)));

  -- 4. The move is the conversion's to make, never the caller's to name.
  v_r := erp.open_document('requisition', v_party, null, v_site);
  perform erp.add_document_line(v_r, v_item, 3, 1000, 'Three widgets');
  perform erp.transition_document(v_r, 'submit');
  perform erp_test.approve_document(v_r, 'suite');
  select count(*) into v_n from erp.document d where d.tenant_id = r.tenant_id;
  begin
    perform erp.convert_document(v_r, null, null, null, 'inherit_approval');
    v_ok := false; v_msg := 'a conversion naming inherit_approval was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_APPROVAL_NOT_CARRIED:%'; v_msg := left(sqlerrm, 80);
  end;
  select count(*) into v_n2 from erp.document d where d.tenant_id = r.tenant_id;
  return query select 'naming the move in a conversion is refused, and nothing is created',
    v_ok and v_n2 = v_n and erp.object_current_state('document', v_r) = 'approved',
    format('%s (documents %s before, %s after)', v_msg, v_n, v_n2);

  -- 5. The same requisition, ordered from somebody else.
  res := erp.convert_document(v_r, v_party2, null, null, 'auto');
  v_po5 := (res ->> 'document_id')::uuid;
  return query select 'an order to another supplier asks for its own approval',
    not coalesce((res ->> 'born_approved')::boolean, false)
    and res ->> 'approval_not_carried' = 'supplier_differs'
    and erp.object_current_state('document', v_po5) = 'pending_approval'
    and exists (select 1 from erp.approval_request q
                 where q.tenant_id = r.tenant_id and q.object_id = v_po5 and q.status = 'pending'),
    format('not carried: %s, %s', res ->> 'approval_not_carried', erp.object_current_state('document', v_po5));

  -- 6. Chains are chosen by entity and site, so another site is another
  -- approval. No move named: the order stays a draft (D1).
  v_r := erp.open_document('requisition', v_party, null, v_site);
  perform erp.add_document_line(v_r, v_item, 6, 1000, 'Six widgets');
  perform erp.transition_document(v_r, 'submit');
  perform erp_test.approve_document(v_r, 'suite');
  res := erp.convert_document(v_r, null, v_site2, null);
  v_po6 := (res ->> 'document_id')::uuid;
  return query select 'an order to another site asks for its own approval',
    not coalesce((res ->> 'born_approved')::boolean, false)
    and res ->> 'approval_not_carried' = 'site_differs'
    and erp.object_current_state('document', v_po6) = 'draft',
    format('not carried: %s, %s', res ->> 'approval_not_carried', erp.object_current_state('document', v_po6));

  -- 7. Case 5's order, refused by its approver and sent back.
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_po5 and tk.status = 'pending'
  loop perform erp.decide_approval_task(t.id, false, 'wrong supplier'); end loop;
  perform erp.transition_document(v_po5, 'reject', 'refused');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  begin
    perform public.erp_transition_document(v_po5, 'inherit_approval', 'by hand');
    v_ok := false; v_msg := 'a refused order was approved by pressing the move';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_APPROVAL_NOT_CARRIED:%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a refused order sent back to draft is not approved by pressing the move',
    v_ok and erp.object_current_state('document', v_po5) = 'draft',
    format('%s; order %s', v_msg, erp.object_current_state('document', v_po5));

  -- 8. Created with the move named.
  select count(*) into v_n from erp.document d where d.tenant_id = r.tenant_id;
  begin
    perform public.erp_create_document_full('purchase_order', v_party, v_site, null, null, null,
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 4, 'unit_price_minor', 1000)),
      'inherit_approval');
    v_ok := false; v_msg := 'a direct order was created approved';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_APPROVAL_NOT_CARRIED:%'; v_msg := left(sqlerrm, 80);
  end;
  select count(*) into v_n2 from erp.document d where d.tenant_id = r.tenant_id;
  return query select 'a direct order cannot be created with the move',
    v_ok and v_n2 = v_n, format('%s (documents %s before, %s after)', v_msg, v_n, v_n2);

  -- 9. A direct order linked by hand to an approved requisition: any buyer can
  -- write a document relation, and one carries nothing.
  v_r := erp.open_document('requisition', v_party, null, v_site);
  perform erp.add_document_line(v_r, v_item, 4, 1000, 'Four widgets');
  perform erp.transition_document(v_r, 'submit');
  perform erp_test.approve_document(v_r, 'suite');
  v_a := erp.open_document('purchase_order', v_party, null, v_site);
  perform erp.add_document_line(v_a, v_item, 4, 1000, 'Four widgets');
  perform erp.link_documents(v_a, v_r, 'converts');
  v_why := erp.conversion_keeps_approval(v_a) ->> 'reason';
  begin
    perform public.erp_transition_document(v_a, 'inherit_approval', 'by hand');
    v_ok := false; v_msg := 'a linked order was approved by pressing the move';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_APPROVAL_NOT_CARRIED:%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a direct order linked by hand carries nothing, and the hand press is refused',
    v_ok and v_why = 'lineage_not_line_level' and erp.object_current_state('document', v_a) = 'draft',
    format('facts: %s; %s', v_why, v_msg);

  -- 10. Case 6's order, its site set back (a direct write, for the test): a
  -- fresh converted draft of which every fact holds. The marker is what
  -- still refuses the hand.
  update erp.document set site_id = v_site where tenant_id = r.tenant_id and id = v_po6;
  v_carry := erp.conversion_keeps_approval(v_po6);
  begin
    perform public.erp_transition_document(v_po6, 'inherit_approval', 'by hand');
    v_ok := false; v_msg := 'a converted draft was approved by pressing the move';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_APPROVAL_NOT_CARRIED:%only by the conversion that raises it%';
    v_msg := left(sqlerrm, 100);
  end;
  return query select 'a fresh converted draft whose every fact holds is still refused by hand',
    v_ok and coalesce((v_carry ->> 'holds')::boolean, false)
    and erp.object_current_state('document', v_po6) = 'draft',
    format('facts hold: %s; %s', coalesce(v_carry ->> 'holds', 'null'), v_msg);

  -- 11. With the marker set, each fact still refuses on its own. A copy of
  -- that order, written yesterday.
  v_copy := gen_random_uuid();
  insert into erp.document
  select (jsonb_populate_record(null::erp.document,
            to_jsonb(d) || jsonb_build_object('id', v_copy, 'created_at', now() - interval '1 day',
                                              'document_number', d.document_number || '-Y'))).*
    from erp.document d where d.tenant_id = r.tenant_id and d.id = v_po6;
  v_why := erp.conversion_keeps_approval(v_copy) ->> 'reason';
  perform set_config('erp.carrying_approval', v_copy::text, true);
  begin
    perform erp.transition_document(v_copy, 'inherit_approval', 'forced');
    v_ok := false; v_msg := 'an order written yesterday was approved with the marker set';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_APPROVAL_NOT_CARRIED:%(not_created_in_this_transaction)%';
    v_msg := left(sqlerrm, 120);
  end;
  perform set_config('erp.carrying_approval', '', true);
  return query select 'with the marker set, an order written yesterday is refused',
    v_ok and v_why = 'not_created_in_this_transaction', v_msg;

  -- 13, computed before 12 because 12's order has moved: case 10's order,
  -- asked about on its own, not moved.
  perform erp.request_approval('document', v_po6, erp.document_transition_context(v_po6, 'submit'), 1,
                               r.entity_id, v_site);
  v_why := erp.conversion_keeps_approval(v_po6) ->> 'reason';
  perform set_config('erp.carrying_approval', v_po6::text, true);
  begin
    perform erp.transition_document(v_po6, 'inherit_approval', 'forced');
    v_ok13 := false; v_msg13 := 'an order with its own request was approved with the marker set';
  exception when others then
    v_ok13 := sqlerrm like 'CLOVEERP_APPROVAL_NOT_CARRIED:%(order_has_approval_request)%';
    v_msg13 := left(sqlerrm, 120);
  end;
  perform set_config('erp.carrying_approval', '', true);
  v_ok13 := v_ok13 and v_why = 'order_has_approval_request'
            and erp.object_current_state('document', v_po6) = 'draft';

  -- 12. Case 7's order, back in draft and its supplier set back (a direct
  -- write): it has moved, and that alone refuses it.
  update erp.document set party_id = v_party where tenant_id = r.tenant_id and id = v_po5;
  v_why := erp.conversion_keeps_approval(v_po5) ->> 'reason';
  perform set_config('erp.carrying_approval', v_po5::text, true);
  begin
    perform erp.transition_document(v_po5, 'inherit_approval', 'forced');
    v_ok := false; v_msg := 'an order that has moved was approved with the marker set';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_APPROVAL_NOT_CARRIED:%(order_has_moved)%';
    v_msg := left(sqlerrm, 120);
  end;
  perform set_config('erp.carrying_approval', '', true);
  return query select 'with the marker set, an order that has moved is refused',
    v_ok and v_why = 'order_has_moved' and erp.object_current_state('document', v_po5) = 'draft', v_msg;

  return query select 'with the marker set, an order with a request of its own is refused',
    v_ok13, v_msg13;

  -- 14. Nobody approved a supplier.
  v_r := erp.open_document('requisition', null, null, v_site);
  perform erp.add_document_line(v_r, v_item, 4, 1000, 'Four widgets');
  perform erp.transition_document(v_r, 'submit');
  perform erp_test.approve_document(v_r, 'suite');
  res := erp.convert_document(v_r, v_party, null, null);
  return query select 'a requisition that names no supplier carries nothing',
    not coalesce((res ->> 'born_approved')::boolean, false)
    and res ->> 'approval_not_carried' = 'no_supplier_named'
    and erp.object_current_state('document', (res ->> 'document_id')::uuid) = 'draft',
    format('not carried: %s', res ->> 'approval_not_carried');

  -- 15. Raised after it was approved.
  v_r := erp.open_document('requisition', v_party, null, v_site);
  v_l := erp.add_document_line(v_r, v_item, 1, 1000, 'One widget');
  perform erp.transition_document(v_r, 'submit');
  perform erp_test.approve_document(v_r, 'suite');
  perform erp.amend_document_line(v_l, 9, 'raised after approval');
  res := erp.convert_document(v_r, null, null, null);
  return query select 'a requisition changed after approval carries nothing',
    not coalesce((res ->> 'born_approved')::boolean, false)
    and res ->> 'approval_not_carried' = 'lines_changed_since_approval',
    format('not carried: %s', res ->> 'approval_not_carried');

  -- 16. Changed while pending and put back after approval: the lines match
  -- what was approved, but the approver may have been shown something else.
  -- As separate transactions would see it: the line written two minutes back
  -- and the request one minute back (touch_attribution keeps a supplied
  -- created_at; requested_at is a plain column). Within one transaction the
  -- timestamps tie, which is why the backdating. A control built the same way
  -- and left alone carries.
  v_r := erp.open_document('requisition', v_party, null, v_site);
  select d.currency into v_cur from erp.document d where d.id = v_r;
  insert into erp.document_line (tenant_id, document_id, line_no, item_id, description, quantity, uom_id,
                                 unit_price_minor, net_minor, currency, created_at)
  values (r.tenant_id, v_r, 10, v_item, 'Four hundred widgets', 400, erp.item_line_uom(v_item, v_req_type),
          1000, 400000, v_cur, now() - interval '2 minutes');
  perform erp.transition_document(v_r, 'submit');
  update erp.approval_request set requested_at = now() - interval '1 minute'
   where tenant_id = r.tenant_id and object_id = v_r and status = 'pending';
  perform erp_test.approve_document(v_r, 'suite');
  res2 := erp.convert_document(v_r, null, null, null);

  v_r := erp.open_document('requisition', v_party, null, v_site);
  insert into erp.document_line (tenant_id, document_id, line_no, item_id, description, quantity, uom_id,
                                 unit_price_minor, net_minor, currency, created_at)
  values (r.tenant_id, v_r, 10, v_item, 'Four hundred widgets', 400, erp.item_line_uom(v_item, v_req_type),
          1000, 400000, v_cur, now() - interval '2 minutes') returning id into v_l;
  perform erp.transition_document(v_r, 'submit');
  update erp.approval_request set requested_at = now() - interval '1 minute'
   where tenant_id = r.tenant_id and object_id = v_r and status = 'pending';
  perform public.erp_amend_document_line(v_l, 4, 'down while pending');
  perform erp_test.approve_document(v_r, 'suite');
  perform public.erp_amend_document_line(v_l, 400, 'back up after approval');
  res := erp.convert_document(v_r, null, null, null);
  return query select 'a requisition changed while pending and put back after approval carries nothing',
    coalesce((res2 ->> 'born_approved')::boolean, false)
    and not coalesce((res ->> 'born_approved')::boolean, false)
    and res ->> 'approval_not_carried' = 'requisition_changed_since_request',
    format('control born approved: %s; changed and put back: %s',
      res2 ->> 'born_approved', coalesce(res ->> 'approval_not_carried', 'carried'));

  -- 17. The conversion takes the unit from the item master, not from the
  -- requisition line.
  v_r := erp.open_document('requisition', v_party, null, v_site);
  perform erp.add_document_line(v_r, v_item2, 4, 1000, 'Four gadgets');
  perform erp.transition_document(v_r, 'submit');
  perform erp_test.approve_document(v_r, 'suite');
  update erp.item set purchase_uom_id = v_box where tenant_id = r.tenant_id and id = v_item2;
  res := erp.convert_document(v_r, null, null, null);
  return query select 'an item whose purchase unit changed between approval and conversion carries nothing',
    not coalesce((res ->> 'born_approved')::boolean, false)
    and res ->> 'approval_not_carried' = 'order_line_not_carried'
    and (select ol.uom_id from erp.document_line ol where ol.document_id = (res ->> 'document_id')::uuid limit 1) = v_box,
    format('not carried: %s, order unit %s', res ->> 'approval_not_carried',
      (select u.code from erp.document_line ol join erp.uom u on u.id = ol.uom_id
        where ol.document_id = (res ->> 'document_id')::uuid limit 1));

  -- 18. D6, rounding only. 1.5 kg at 3 is approved at 5; three orders of
  -- 0.5 kg at 3 are 2 each, 6 together: one minor unit a line, which carries.
  -- An order amended up after its birth leaves the rest nothing to carry.
  v_r := erp.open_document('requisition', v_party, null, v_site);
  v_l := erp.add_document_line(v_r, v_item3, 1.5, 3, 'Flour');
  perform erp.transition_document(v_r, 'submit');
  perform erp_test.approve_document(v_r, 'suite');
  v_n := 0; v_n2 := 0;
  for i in 1..3 loop
    res := erp.convert_document(v_r, null, null,
             jsonb_build_array(jsonb_build_object('line_id', v_l, 'quantity', 0.5)));
    if coalesce((res ->> 'born_approved')::boolean, false) then v_n := v_n + 1; end if;
    v_n2 := v_n2 + erp.document_value_minor((res ->> 'document_id')::uuid);
  end loop;
  v_ok := v_n = 3 and v_n2 = erp.document_value_minor(v_r) + 1;
  v_msg := format('three thirds of %s: %s born approved, %s together', erp.document_value_minor(v_r), v_n, v_n2);

  v_r := erp.open_document('requisition', v_party, null, v_site);
  v_l := erp.add_document_line(v_r, v_item, 4, 1000, 'Four widgets');
  perform erp.transition_document(v_r, 'submit');
  perform erp_test.approve_document(v_r, 'suite');
  res := erp.convert_document(v_r, null, null,
           jsonb_build_array(jsonb_build_object('line_id', v_l, 'quantity', 2)));
  perform erp.amend_document_line(
    (select ol.id from erp.document_line ol where ol.document_id = (res ->> 'document_id')::uuid), 4, 'more');
  res2 := erp.convert_document(v_r, null, null, null);
  return query select 'part orders never add up past the approved value beyond rounding',
    v_ok and coalesce((res ->> 'born_approved')::boolean, false)
    and not coalesce((res2 ->> 'born_approved')::boolean, false)
    and res2 ->> 'approval_not_carried' = 'over_approved_value',
    format('%s; first part amended up to the whole, then the rest: %s',
      v_msg, coalesce(res2 ->> 'approval_not_carried', 'carried'));

  -- 19. A negative line that makes a large one look small.
  v_r := erp.open_document('requisition', v_party, null, v_site);
  perform erp.add_document_line(v_r, v_item, 10, 5000000, 'Big');
  perform erp.add_document_line(v_r, v_item, -10, 4999900, 'Offset');
  perform erp.transition_document(v_r, 'submit');
  perform erp_test.approve_document(v_r, 'suite');
  res := erp.convert_document(v_r, null, null, null);
  return query select 'offsetting lines carry nothing',
    not coalesce((res ->> 'born_approved')::boolean, false)
    and res ->> 'approval_not_carried' = 'requisition_line_not_positive',
    format('approved at %s, not carried: %s', erp.document_value_minor(v_r), res ->> 'approval_not_carried');

  -- 20. Nothing priced is nothing approved.
  v_r := erp.open_document('requisition', v_party, null, v_site);
  perform erp.add_document_line(v_r, v_item, 3, 0, 'Free');
  perform erp.transition_document(v_r, 'submit');
  perform erp_test.approve_document(v_r, 'suite');
  res := erp.convert_document(v_r, null, null, null);
  return query select 'a zero-priced line carries nothing',
    not coalesce((res ->> 'born_approved')::boolean, false)
    and res ->> 'approval_not_carried' = 'order_line_not_carried',
    format('not carried: %s', res ->> 'approval_not_carried');

  -- 21. A request raised before M2 recorded no line fingerprint (written
  -- away here, as such a request reads).
  v_r := erp.open_document('requisition', v_party, null, v_site);
  perform erp.add_document_line(v_r, v_item, 4, 1000, 'Four widgets');
  perform erp.transition_document(v_r, 'submit');
  perform erp_test.approve_document(v_r, 'suite');
  update erp.approval_request set context = context - 'line_fingerprint'
   where tenant_id = r.tenant_id and object_type = 'document' and object_id = v_r;
  res := erp.convert_document(v_r, null, null, null);
  return query select 'an approval requested before M2 carries nothing',
    not coalesce((res ->> 'born_approved')::boolean, false)
    and res ->> 'approval_not_carried' = 'lines_changed_since_approval',
    format('not carried: %s', res ->> 'approval_not_carried');

  -- 22. Cancelled, or refused and sent back: neither is approved.
  v_a := erp.open_document('requisition', v_party, null, v_site);
  perform erp.add_document_line(v_a, v_item, 4, 1000, 'Four widgets');
  perform erp.transition_document(v_a, 'cancel', 'not needed');
  v_b := erp.open_document('requisition', v_party, null, v_site);
  perform erp.add_document_line(v_b, v_item, 4, 1000, 'Four widgets');
  perform erp.transition_document(v_b, 'submit');
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_b and tk.status = 'pending'
  loop perform erp.decide_approval_task(t.id, false, 'not this'); end loop;
  perform erp.transition_document(v_b, 'reject', 'refused');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  select count(*) into v_n from erp.document d where d.tenant_id = r.tenant_id;
  begin
    perform erp.convert_document(v_a, null, null, null);
    v_ok := false; v_msg := 'a cancelled requisition converted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_DOCUMENT_CANCELLED:%' or sqlerrm like 'CLOVEERP_NOT_APPROVED_YET:%';
    v_msg := left(sqlerrm, 60);
  end;
  begin
    perform erp.convert_document(v_b, null, null, null);
    v_ok2 := false; v_msg2 := 'a refused requisition converted';
  exception when others then
    v_ok2 := sqlerrm like 'CLOVEERP_NOT_APPROVED_YET:%'; v_msg2 := left(sqlerrm, 60);
  end;
  select count(*) into v_n2 from erp.document d where d.tenant_id = r.tenant_id;
  return query select 'a cancelled requisition, or one sent back, converts nothing',
    v_ok and v_ok2 and v_n2 = v_n,
    format('cancelled (%s): %s; sent back (%s): %s; documents %s before, %s after',
      erp.object_current_state('document', v_a), v_msg,
      erp.object_current_state('document', v_b), v_msg2, v_n, v_n2);

  -- 23. Case 1's event, read while its order is as it was born.
  select ev.payload into v_carry from erp.event ev
   where ev.tenant_id = r.tenant_id and ev.aggregate_id = v_po1
     and ev.event_type = 'document.approval_carried';
  return query select 'the carried event names the parent request and records the order''s fingerprint and value',
    v_carry ->> 'approval_request_id' = v_q::text
    and v_carry ->> 'requisition_id' = v_r1::text
    and (v_carry ->> 'value_at_approval')::numeric = 10000
    and v_carry ->> 'party_id' = v_party::text
    and v_carry ->> 'order_line_fingerprint' = erp.document_line_fingerprint(v_po1)
    and (v_carry ->> 'order_value_minor')::bigint = erp.document_value_minor(v_po1)
    and not (v_carry ? 'holds') and not (v_carry ? 'reason'),
    format('request %s, approved at %s, order value %s, fingerprint %s',
      case when v_carry ->> 'approval_request_id' = v_q::text then 'the requisition''s' else coalesce(v_carry ->> 'approval_request_id', 'none') end,
      v_carry ->> 'value_at_approval', v_carry ->> 'order_value_minor',
      case when v_carry ->> 'order_line_fingerprint' = erp.document_line_fingerprint(v_po1) then 'matches' else 'differs' end);

  -- 24. D5 (a): the born order is issued as it was converted, or not at all.
  select ol.id into v_l from erp.document_line ol where ol.document_id = v_po1;
  perform public.erp_amend_document_line(v_l, 5, 'one more after birth');
  begin
    perform public.erp_transition_document(v_po1, 'send', null);
    v_ok := false; v_msg := 'a changed born order was issued';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_CARRIED_ORDER_CHANGED:%'; v_msg := left(sqlerrm, 80);
  end;
  perform public.erp_amend_document_line(v_l, 4, 'put back');
  begin
    v_msg2 := public.erp_transition_document(v_po1, 'send', null)::text;
  exception when others then v_msg2 := 'refused: ' || left(sqlerrm, 60); end;
  return query select 'a changed born order is not issued, and once put back it is',
    v_ok and erp.object_current_state('document', v_po1) = 'sent',
    format('changed: %s | put back: %s', v_msg, v_msg2);

  -- 25. Every other reason, one at a time. Each row starts from a conversion
  -- that would carry — converted to the second site so it stays a draft, its
  -- site then set back, and the check holding — changes one fact by a direct
  -- write where no door reaches it, and expects the check to name that
  -- reason and the press, with the marker set, to be refused.
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'CO2','Second Company','active') returning id into v_b;
  insert into erp.entity (tenant_id, code, name, base_currency, party_id)
  values (r.tenant_id, 'CO2', 'Second Company', 'GBP', v_b) returning id into v_entity2;
  v_rows := 0; v_fail := null;
  foreach v_reason in array array[
      'not_an_open_purchase_order', 'lineage_not_one_requisition', 'not_from_a_requisition',
      'requisition_not_approved', 'latest_request_not_approved', 'approved_by_nobody',
      'no_value_at_approval', 'currency_differs', 'entity_differs', 'family_not_comparable'] loop
    v_rows := v_rows + 1;
    v_r := erp.open_document('requisition', v_party, null, v_site);
    v_l := erp.add_document_line(v_r, v_item, 10, 1000, 'Ten widgets');
    perform erp.transition_document(v_r, 'submit');
    perform erp_test.approve_document(v_r, 'suite');
    select q.id into v_q from erp.approval_request q
     where q.tenant_id = r.tenant_id and q.object_type = 'document' and q.object_id = v_r
       and q.status = 'approved';
    res := erp.convert_document(v_r, null, v_site2,
             jsonb_build_array(jsonb_build_object('line_id', v_l, 'quantity', 5)));
    v_a := (res ->> 'document_id')::uuid;
    update erp.document set site_id = v_site where tenant_id = r.tenant_id and id = v_a;
    v_carry := erp.conversion_keeps_approval(v_a);
    if not coalesce((v_carry ->> 'holds')::boolean, false) then
      v_fail := concat_ws('; ', v_fail, format('%s: the start did not carry (%s)', v_reason, v_carry ->> 'reason'));
      continue;
    end if;

    if v_reason = 'not_an_open_purchase_order' then
      update erp.document set is_cancelled = true, cancelled_at = now(), cancellation_reason = 'suite'
       where tenant_id = r.tenant_id and id = v_a;
    elsif v_reason = 'lineage_not_one_requisition' then
      insert into erp.document_relation (tenant_id, from_document_id, to_document_id, relation_kind)
      values (r.tenant_id, v_a, v_r1, 'fulfils');
    elsif v_reason = 'not_from_a_requisition' then
      update erp.document set is_cancelled = true, cancelled_at = now(), cancellation_reason = 'suite'
       where tenant_id = r.tenant_id and id = v_r;
    elsif v_reason = 'requisition_not_approved' then
      update erp.object_state os set current_state_id = s.id
        from erp.state s
       where os.tenant_id = r.tenant_id and os.object_type = 'document' and os.object_id = v_r
         and s.tenant_id = os.tenant_id and s.state_machine_version_id = os.state_machine_version_id
         and s.code = 'submitted';
    elsif v_reason = 'latest_request_not_approved' then
      insert into erp.approval_request
      select (jsonb_populate_record(null::erp.approval_request,
                to_jsonb(q) || jsonb_build_object('id', gen_random_uuid(), 'status', 'pending',
                                                  'requested_at', now(), 'decided_at', null,
                                                  'value_at_approval', null))).*
        from erp.approval_request q where q.tenant_id = r.tenant_id and q.id = v_q;
    elsif v_reason = 'approved_by_nobody' then
      update erp.approval_task set decided_by = null
       where tenant_id = r.tenant_id and approval_request_id = v_q;
    elsif v_reason = 'no_value_at_approval' then
      update erp.approval_request set value_at_approval = null
       where tenant_id = r.tenant_id and id = v_q;
    elsif v_reason = 'currency_differs' then
      update erp.document set currency = 'EUR' where tenant_id = r.tenant_id and id = v_a;
    elsif v_reason = 'entity_differs' then
      update erp.document set entity_id = v_entity2 where tenant_id = r.tenant_id and id = v_a;
    elsif v_reason = 'family_not_comparable' then
      -- Another order of the family, in another currency: the sum no longer
      -- means anything.
      res2 := erp.convert_document(v_r, null, v_site2, null);
      update erp.document set currency = 'EUR'
       where tenant_id = r.tenant_id and id = (res2 ->> 'document_id')::uuid;
    end if;

    v_why := erp.conversion_keeps_approval(v_a) ->> 'reason';
    perform set_config('erp.carrying_approval', v_a::text, true);
    begin
      perform erp.transition_document(v_a, 'inherit_approval', 'forced');
      v_msg := 'accepted';
    exception when others then v_msg := left(sqlerrm, 120); end;
    perform set_config('erp.carrying_approval', '', true);

    if v_why is distinct from v_reason
       or v_msg not like 'CLOVEERP_%'
       or coalesce(erp.object_current_state('document', v_a), '') = 'approved' then
      v_fail := concat_ws('; ', v_fail,
        format('%s: check said %s, press %s, order %s', v_reason, coalesce(v_why, 'nothing'),
               v_msg, erp.object_current_state('document', v_a)));
    end if;
  end loop;
  return query select 'every other reason refuses on its own',
    v_rows = 10 and v_fail is null,
    coalesce(v_fail, format('%s of %s reasons each refused alone, the press refused with the marker set', v_rows, v_rows));

  -- 26. Two conversions of one requisition at once would over-convert it.
  return query select 'convert_document takes the advisory lock',
    position('pg_advisory_xact_lock(hashtext(''erp.convert_document:''' in
             (select p.prosrc from pg_proc p
               where p.oid = 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'::regprocedure)) > 0,
    'pg_advisory_xact_lock on the tenant and the requisition, before anything is read';

  -- 27. PR4_plan.md:234's open risk. A blanket is an agreement and posts
  -- nothing; its call-off is sent, posting the commitment, and received by
  -- its goods through erp.advance_orders_for_receipt(), which must not post
  -- it again — nor when it is run a second time.
  v_b := erp.open_document('purchase_order', v_party, null, v_site);
  v_bl := erp.add_document_line(v_b, v_item, 100, 500, 'Agreed for the year');
  perform erp.set_order_behaviour(v_b, 'blanket', current_date + 180);
  perform erp.transition_document(v_b, 'submit');
  perform erp_test.approve_document(v_b, 'suite');
  perform erp.transition_document(v_b, 'send');
  v_co := erp.call_off_blanket_order(v_b,
            jsonb_build_array(jsonb_build_object('line_id', v_bl, 'quantity', 30)));
  perform erp.transition_document(v_co, 'submit');
  perform erp_test.approve_document(v_co, 'suite');
  perform erp.transition_document(v_co, 'send');
  select count(*) into v_n from erp.journal j where j.tenant_id = r.tenant_id and j.document_id = v_co;
  res := erp.create_receipt_from_order(v_co, null, 'post');
  v_grn := (res ->> 'document_id')::uuid;
  perform erp.advance_orders_for_receipt(v_grn);
  select count(*) into v_n2 from erp.journal j where j.tenant_id = r.tenant_id and j.document_id = v_co;
  return query select 'a blanket order''s call-off, received, posts its commitment only once',
    v_n = 1 and v_n2 = 1
    and erp.object_current_state('document', v_co) = 'received'
    and not exists (select 1 from erp.journal j where j.tenant_id = r.tenant_id and j.document_id = v_b)
    and not exists (select 1 from erp.event ev where ev.tenant_id = r.tenant_id and ev.aggregate_id = v_co
                     and ev.event_type = 'document.progress_not_advanced'),
    format('call-off %s; commitment journals %s when sent, %s after the receipt and a second advance; blanket journals %s',
      erp.object_current_state('document', v_co), v_n, v_n2,
      (select count(*) from erp.journal j where j.tenant_id = r.tenant_id and j.document_id = v_b));

  -- Journals are checked by DEFERRABLE INITIALLY DEFERRED triggers, which fire
  -- at commit — after this suite has deleted its own tenant. Firing them here
  -- checks them against data that still exists.
  set constraints all immediate;

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
end;
$$;

create or replace function erp_test.assert_procurement_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 40;
  v_total integer; v_failed integer; v_detail text;
begin
  select count(*), count(*) filter (where not coalesce(r.passed, false)),
         string_agg(format('  %s — %s', r.case_name, r.detail), E'\n')
           filter (where not coalesce(r.passed, false))
    into v_total, v_failed, v_detail
    from erp_test.procurement_suite() r;

  if v_failed > 0 then
    raise exception E'CLOVEERP_PROCUREMENT_SUITE_FAILED: %/% case(s) failed\n%',
      v_failed, v_total, v_detail;
  end if;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_PROCUREMENT_SUITE_INCOMPLETE: expected % cases, ran %',
      c_expected, v_total
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('procurement: %s/%s cases passed', v_total, v_total);
end;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- The reseed suite: an organisation on version 1 of the procurement lifecycle
-- takes version 2 (20260922380000)
--
-- Five organisations, each made here and purged here:
--   A  not live, v1 at the defaults, backdated 30 days, documents in flight
--   F  not live, a fresh install at v2 at the defaults (case 10 only)
--   B  not live, v1 with approver 'purchasing' and threshold 500000
--   D  a demonstration ('demo-…'), not live, on v1
--   C  live, two administrators, v1 backdated, documents in flight seeded
--      before it went live
-- Runs as postgres. erp_ref is written only inside the undo blocks of cases
-- 8, 9 and 14, each rolled back by a private exception before it returns.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.procurement_reseed_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_names constant text[] := array[
    'v1 as it stood: a requisition type with no chain approves on its permission',
    'the upgrade offers exactly the four changes of version 2, and says which replace what the organisation holds',
    'upgraded through Upgrade, v1 ends today and v2 starts today, and both stay active',
    'documents in flight finish on v1: the received order closes on its bill, the part-received one moves on with its next receipt',
    'an approval given on v1 carries nothing',
    'a requisition raised after the upgrade asks for requisition_value, and its order is born approved',
    'in the mixed state the undriven, reachable and dead-configuration reports read 0',
    'a move code the current upgrade payload ships is excused before anyone holds it',
    'a code only an older payload, or another lifecycle, declares is still reported',
    'the upgraded objects equal a fresh version 2 install at the defaults, compared through the manifest',
    'the upgrade rolls back through its snapshot: new documents start on the restored content, documents raised on v2 stay on v2',
    'an organisation that customised v1 keeps its order chain and gets the requisition chain at the defaults',
    'the catch-up upgrades a demonstration once and says so, and a second run plans nothing',
    'an upgrade that raises becomes a note: the demonstration stays on v1 and the catch-up carries on',
    'in a live organisation the upgrade is authored and waits, and its author cannot approve it',
    'a second administrator promotes it, the promotion stamps the installation, and it reads version 2',
    'the live organisation''s documents in flight finish on v1 after the promotion',
    'D2, fail closed: in a live organisation a requisition approved only by its requester carries nothing',
    'the suite leaves nothing behind'];
  v_codes constant text[] := array['zzrsa', 'zzrsf', 'zzrsb', 'demo-zzreseed', 'zzrsc'];
  v_undo  constant text := 'CLOVEERP_RESEED_SUITE_UNDO';
  v_items_before integer;
  v_step  integer := 0;
  v_ok    boolean;
  v_msg   text;
  v_err   text;
  v_purge_err text;
  v_ok14  boolean;
  v_msg14 text;
  i       integer;

  -- Who each organisation's administrators are to the database.
  a_a  uuid := gen_random_uuid();
  a_f  uuid := gen_random_uuid();
  a_b  uuid := gen_random_uuid();
  a_d  uuid := gen_random_uuid();
  a_c  uuid := gen_random_uuid();
  a_c2 uuid := gen_random_uuid();
  u_c2 uuid;
  v_tok text;

  ta uuid; tf uuid; tb uuid; td uuid; tc uuid;
  r  record;
  x  record;
  res jsonb; res2 jsonb;
  v_ent_code text; v_ent uuid; v_site uuid; v_item uuid; v_sup uuid;

  -- Organisation A's documents and versions.
  a_rq_draft uuid; a_rq_sub uuid; a_rq_app uuid;
  a_po_draft uuid; a_po_pend uuid; a_po_app uuid; a_po_sent uuid;
  a_po_part uuid; a_pl_part uuid; a_po_recv uuid; a_pl_recv uuid;
  a_req_v1 uuid; a_po_v1 uuid; a_req_v2 uuid; a_po_v2 uuid;
  a_cs uuid; a_rq_new uuid; a_po_born uuid;
  -- Organisation C's.
  c_po_app uuid; c_po_recv uuid; c_pl_recv uuid; c_rq_sub uuid; c_req_v1 uuid; c_po_v1 uuid;
  c_cs uuid;

  v_doc uuid; v_doc2 uuid; v_line uuid; v_g uuid; v_bill uuid;
  v_st text; v_st2 text; v_n integer; v_n2 integer; v_n3 integer;
  v_a jsonb; v_f jsonb; v_reg jsonb;
begin
  select count(*) into v_items_before from erp_ref.module_upgrade_item;

  begin
    -- ═════════════════════════════════════════════════════════════════════
    -- Organisation A: not live, v1 at the defaults, backdated 30 days
    -- ═════════════════════════════════════════════════════════════════════
    select * into r from erp.provision_tenant('zzrsa', 'Reseed Suite A', 'admin@zzrsa.test', 'Reseed Admin A');
    ta := r.tenant_id; v_ent := r.entity_id;
    perform set_config('request.jwt.claims', json_build_object('sub', a_a)::text, true);
    perform erp.claim_invitation(r.admin_token);
    update erp.environment set is_live = false where tenant_id = ta and is_self;
    perform erp.configure_finance(extract(year from current_date)::integer, null);
    select e.code into v_ent_code from erp.entity e where e.tenant_id = ta and e.id = v_ent;
    perform erp.install_module_config('procurement-lifecycle', 'Procurement lifecycle',
      'Version 1, as an organisation installed it before 20260922380000',
      erp_test.procurement_lifecycle_v1_items(v_ent_code));
    -- install_module_config() records the installer's current version; this
    -- organisation installed version 1, thirty days ago.
    update erp.module_installation
       set installer_version = 1, installed_at = now() - interval '30 days'
     where tenant_id = ta and install_code = 'procurement-lifecycle';
    res := erp.ensure_demo_configuration(ta, r.admin_user_id);
    v_site := (res ->> 'site_id')::uuid;
    update erp.state_machine_version v set effective_from = current_date - 30
      from erp.state_machine m
     where m.tenant_id = ta and m.id = v.state_machine_id and v.tenant_id = ta
       and m.code in ('purchase_order', 'requisition');
    select v.id into a_req_v1 from erp.state_machine_version v join erp.state_machine m on m.id = v.state_machine_id
     where m.tenant_id = ta and m.code = 'requisition' and v.version = 1;
    select v.id into a_po_v1 from erp.state_machine_version v join erp.state_machine m on m.id = v.state_machine_id
     where m.tenant_id = ta and m.code = 'purchase_order' and v.version = 1;
    select it.id into v_item from erp.item it where it.tenant_id = ta and it.status = 'active' order by it.code limit 1;
    select p.id into v_sup from erp.party p
      join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id and pr.role_kind = 'supplier'
     where p.tenant_id = ta and p.status = 'active' order by p.code limit 1;

    -- In flight on v1.
    a_rq_draft := erp.open_document('requisition', v_sup, v_ent, v_site);
    perform erp.add_document_line(a_rq_draft, v_item, 3, 1000, 'v1 draft');
    a_rq_sub := erp.open_document('requisition', v_sup, v_ent, v_site);
    perform erp.add_document_line(a_rq_sub, v_item, 3, 1000, 'v1 submitted');
    perform erp.transition_document(a_rq_sub, 'submit');
    a_rq_app := erp.open_document('requisition', v_sup, v_ent, v_site);
    perform erp.add_document_line(a_rq_app, v_item, 3, 1000, 'v1 approved');
    perform erp.transition_document(a_rq_app, 'submit');
    v_st := erp.transition_document(a_rq_app, 'approve');

    a_po_draft := erp.open_document('purchase_order', v_sup, v_ent, v_site);
    perform erp.add_document_line(a_po_draft, v_item, 10, 1000, 'v1 order draft');
    a_po_pend := erp.open_document('purchase_order', v_sup, v_ent, v_site);
    perform erp.add_document_line(a_po_pend, v_item, 10, 1000, 'v1 order pending');
    perform erp.transition_document(a_po_pend, 'submit');
    a_po_app := erp.open_document('purchase_order', v_sup, v_ent, v_site);
    perform erp.add_document_line(a_po_app, v_item, 10, 1000, 'v1 order approved');
    perform erp.transition_document(a_po_app, 'submit');
    perform erp_test.approve_document(a_po_app, 'the reseed suite');
    a_po_sent := erp.open_document('purchase_order', v_sup, v_ent, v_site);
    perform erp.add_document_line(a_po_sent, v_item, 10, 1000, 'v1 order sent');
    perform erp.transition_document(a_po_sent, 'submit');
    perform erp_test.approve_document(a_po_sent, 'the reseed suite');
    perform erp.transition_document(a_po_sent, 'send');
    a_po_part := erp.open_document('purchase_order', v_sup, v_ent, v_site);
    a_pl_part := erp.add_document_line(a_po_part, v_item, 10, 1000, 'v1 order part received');
    perform erp.transition_document(a_po_part, 'submit');
    perform erp_test.approve_document(a_po_part, 'the reseed suite');
    perform erp.transition_document(a_po_part, 'send');
    v_g := erp.open_document('goods_receipt', v_sup, v_ent, v_site);
    perform erp.receive_against(v_g, a_pl_part, 4, null);
    perform erp.transition_document(v_g, 'post');
    a_po_recv := erp.open_document('purchase_order', v_sup, v_ent, v_site);
    a_pl_recv := erp.add_document_line(a_po_recv, v_item, 10, 1000, 'v1 order received');
    perform erp.transition_document(a_po_recv, 'submit');
    perform erp_test.approve_document(a_po_recv, 'the reseed suite');
    perform erp.transition_document(a_po_recv, 'send');
    v_g := erp.open_document('goods_receipt', v_sup, v_ent, v_site);
    perform erp.receive_against(v_g, a_pl_recv, 10, null);
    perform erp.transition_document(v_g, 'post');

    -- ── 1 ────────────────────────────────────────────────────────────────
    select count(*) into v_n from erp.approval_request q where q.tenant_id = ta and q.object_id = a_rq_app;
    v_ok := v_st = 'approved' and v_n = 0
      and (select dt.approval_chain_code from erp.document_type dt where dt.tenant_id = ta and dt.code = 'requisition') is null
      and (select os.state_machine_version_id from erp.object_state os
            where os.tenant_id = ta and os.object_type = 'document' and os.object_id = a_rq_app) = a_req_v1;
    v_msg := format('the v1 requisition moved to %s with %s approval request(s); its type names chain %s',
                    v_st, v_n, coalesce((select dt.approval_chain_code from erp.document_type dt
                                          where dt.tenant_id = ta and dt.code = 'requisition'), 'none'));
    return query select v_names[1], coalesce(v_ok, false), v_msg; v_step := 1;

    -- ── 2 ────────────────────────────────────────────────────────────────
    select count(*),
           count(*) filter (where p.effect = 'a newer version of configuration the organisation holds, which replaces it'
                              and (p.object_kind, p.object_key) in (('state_machine','requisition'),
                                    ('state_machine','purchase_order'), ('document_type','requisition'))),
           count(*) filter (where p.effect = 'configuration the organisation lacks'
                              and (p.object_kind, p.object_key) = ('approval_chain','requisition_value')),
           string_agg(p.object_kind || '.' || p.object_key || ' [' || p.effect || ']', '; ' order by p.seq)
      into v_n, v_n2, v_n3, v_msg
      from erp.plan_module_upgrade('procurement-lifecycle') p
     where p.to_version = 2
       and exists (select 1 from erp_ref.module_upgrade_item ui
                    where ui.install_code = 'procurement-lifecycle' and ui.to_version = 2
                      and ui.object_kind = p.object_kind and ui.object_key = p.object_key
                      and ui.payload = p.payload);
    v_ok := v_n = 4 and v_n2 = 3 and v_n3 = 1
      and (select count(*) from erp.plan_module_upgrade('procurement-lifecycle')) = 4;
    return query select v_names[2], coalesce(v_ok, false), coalesce(v_msg, 'nothing planned'); v_step := 2;

    -- ── 3 ────────────────────────────────────────────────────────────────
    res := erp.upgrade_module_configuration('procurement-lifecycle');
    a_cs := (res ->> 'change_set_id')::uuid;
    select v.id into a_req_v2 from erp.state_machine_version v join erp.state_machine m on m.id = v.state_machine_id
     where m.tenant_id = ta and m.code = 'requisition' and v.version = 2;
    select v.id into a_po_v2 from erp.state_machine_version v join erp.state_machine m on m.id = v.state_machine_id
     where m.tenant_id = ta and m.code = 'purchase_order' and v.version = 2;
    select string_agg(format('%s v%s %s %s..%s', m.code, v.version, v.status, v.effective_from,
                             coalesce(v.effective_to::text, '')), ', ' order by m.code, v.version),
           count(*) filter (where v.version = 1 and v.status = 'active' and v.effective_to = current_date),
           count(*) filter (where v.version = 2 and v.status = 'active' and v.effective_from = current_date
                              and v.effective_to is null)
      into v_msg, v_n, v_n2
      from erp.state_machine m join erp.state_machine_version v on v.state_machine_id = m.id
     where m.tenant_id = ta and m.code in ('requisition', 'purchase_order');
    v_ok := (res ->> 'promoted')::boolean and (res ->> 'items')::integer = 4 and (res ->> 'to_version')::integer = 2
      and v_n = 2 and v_n2 = 2
      and (select count(*) from erp.state_machine m join erp.state_machine_version v on v.state_machine_id = m.id
            where m.tenant_id = ta and m.code in ('requisition', 'purchase_order')) = 4
      and (select i.installer_version = 2 and i.pending_change_set_id is null and i.change_set_id = a_cs
             from erp.module_installation i where i.tenant_id = ta and i.install_code = 'procurement-lifecycle');
    return query select v_names[3], coalesce(v_ok, false), format('%s; %s', res - 'change_set_id', v_msg); v_step := 3;

    -- ── 4 ────────────────────────────────────────────────────────────────
    v_bill := erp.open_document('purchase_invoice', v_sup, v_ent, v_site);
    perform erp.invoice_against(v_bill, a_pl_recv, 10, 1000);
    update erp.document set their_reference = 'ZZRS-A-1', due_date = current_date + 30
     where tenant_id = ta and id = v_bill;
    perform erp.transition_document(v_bill, 'register');
    v_g := erp.open_document('goods_receipt', v_sup, v_ent, v_site);
    perform erp.receive_against(v_g, a_pl_part, 6, null);
    perform erp.transition_document(v_g, 'post');
    v_st := erp.transition_document(a_po_app, 'send');
    v_st2 := erp_test.approve_document(a_po_pend, 'the reseed suite');
    v_ok := erp.object_current_state('document', a_po_recv) = 'closed'
      and erp.object_current_state('document', a_po_part) = 'received'
      and v_st = 'sent' and v_st2 = 'approved'
      and (select st.name from erp.object_state os join erp.state st on st.id = os.current_state_id
            where os.tenant_id = ta and os.object_type = 'document' and os.object_id = a_po_app) = 'Sent to supplier'
      and not exists (select 1 from erp.object_state os
                       where os.tenant_id = ta and os.object_type = 'document'
                         and os.object_id in (a_po_draft, a_po_pend, a_po_app, a_po_sent, a_po_part, a_po_recv)
                         and os.state_machine_version_id <> a_po_v1)
      and not exists (select 1 from erp.object_state os
                       where os.tenant_id = ta and os.object_type = 'document'
                         and os.object_id in (a_rq_draft, a_rq_sub, a_rq_app)
                         and os.state_machine_version_id <> a_req_v1);
    v_msg := format('received order %s, part-received order %s, approved order %s (%s), pending order %s; every one on v1: %s',
                    erp.object_current_state('document', a_po_recv), erp.object_current_state('document', a_po_part),
                    v_st, (select st.name from erp.object_state os join erp.state st on st.id = os.current_state_id
                            where os.tenant_id = ta and os.object_type = 'document' and os.object_id = a_po_app),
                    v_st2,
                    not exists (select 1 from erp.object_state os
                                 where os.tenant_id = ta and os.object_type = 'document'
                                   and os.object_id in (a_po_draft, a_po_pend, a_po_app, a_po_sent, a_po_part, a_po_recv,
                                                        a_rq_draft, a_rq_sub, a_rq_app)
                                   and os.state_machine_version_id not in (a_po_v1, a_req_v1)));
    return query select v_names[4], coalesce(v_ok, false), v_msg; v_step := 4;

    -- ── 5 ────────────────────────────────────────────────────────────────
    res := erp.convert_document(a_rq_app, null, null, null, null);
    perform erp.transition_document(a_rq_sub, 'approve');
    res2 := erp.convert_document(a_rq_sub, null, null, null, null);
    v_ok := not (res ->> 'born_approved')::boolean and res ->> 'approval_not_carried' = 'no_approved_request'
      and erp.object_current_state('document', (res ->> 'document_id')::uuid) = 'draft'
      and not (res2 ->> 'born_approved')::boolean and res2 ->> 'approval_not_carried' = 'no_approved_request'
      and erp.object_current_state('document', (res2 ->> 'document_id')::uuid) = 'draft'
      and not exists (select 1 from erp.event ev where ev.tenant_id = ta and ev.event_type = 'document.approval_carried'
                         and ev.aggregate_id in ((res ->> 'document_id')::uuid, (res2 ->> 'document_id')::uuid));
    v_msg := format('approved on v1: born %s (%s), order %s; approved on v1 after the upgrade: born %s (%s), order %s',
                    res ->> 'born_approved', coalesce(res ->> 'approval_not_carried', 'carried'),
                    erp.object_current_state('document', (res ->> 'document_id')::uuid),
                    res2 ->> 'born_approved', coalesce(res2 ->> 'approval_not_carried', 'carried'),
                    erp.object_current_state('document', (res2 ->> 'document_id')::uuid));
    return query select v_names[5], coalesce(v_ok, false), v_msg; v_step := 5;

    -- ── 6 ────────────────────────────────────────────────────────────────
    a_rq_new := erp.open_document('requisition', v_sup, v_ent, v_site);
    perform erp.add_document_line(a_rq_new, v_item, 5, 1000, 'raised on v2');
    perform erp.transition_document(a_rq_new, 'submit');
    select c.code into v_st from erp.approval_request q join erp.approval_chain c on c.tenant_id = q.tenant_id and c.id = q.approval_chain_id
     where q.tenant_id = ta and q.object_type = 'document' and q.object_id = a_rq_new and q.status = 'pending';
    perform erp.approve_my_document_tasks(a_rq_new, 'the reseed suite');
    if erp.object_current_state('document', a_rq_new) = 'submitted' then
      perform erp.transition_document(a_rq_new, 'approve');
    end if;
    res := erp.convert_document(a_rq_new, null, null, null, null);
    a_po_born := (res ->> 'document_id')::uuid;
    v_ok := v_st = 'requisition_value'
      and (res ->> 'born_approved')::boolean
      and erp.object_current_state('document', a_po_born) = 'approved'
      and erp.object_current_state('document', a_rq_new) = 'ordered'
      and (select os.state_machine_version_id from erp.object_state os
            where os.tenant_id = ta and os.object_type = 'document' and os.object_id = a_rq_new) = a_req_v2
      and (select os.state_machine_version_id from erp.object_state os
            where os.tenant_id = ta and os.object_type = 'document' and os.object_id = a_po_born) = a_po_v2
      and not exists (select 1 from erp.approval_request q where q.tenant_id = ta and q.object_id = a_po_born);
    v_msg := format('asked for %s; order born %s (%s), order %s, requisition %s',
                    coalesce(v_st, 'nothing'), res ->> 'born_approved', coalesce(res ->> 'approval_not_carried', 'carried'),
                    erp.object_current_state('document', a_po_born), erp.object_current_state('document', a_rq_new));
    return query select v_names[6], coalesce(v_ok, false), v_msg; v_step := 6;

    -- ── 7 ────────────────────────────────────────────────────────────────
    select (select count(*) from erp.undriven_transition_report()),
           (select count(*) from erp.reachable_configuration_report()),
           (select count(*) from erp.dead_configuration_report())
      into v_n, v_n2, v_n3;
    v_ok := v_n = 0 and v_n2 = 0 and v_n3 = 0;
    select coalesce(string_agg(f.reference, ', '), '') into v_msg
      from (select u.reference from erp.undriven_transition_report() u
            union all select rc.reference from erp.reachable_configuration_report() rc
            union all select dc.reference from erp.dead_configuration_report() dc) f;
    return query select v_names[7], coalesce(v_ok, false),
      format('undriven %s, reachable %s, dead %s %s', v_n, v_n2, v_n3, v_msg); v_step := 7;

    -- ── 8 ────────────────────────────────────────────────────────────────
    -- A code the current payload ships and no organisation holds: the payload
    -- gains a synthetic move inside this block, which is rolled back.
    v_ok := null; v_msg := null;
    begin
      update erp_ref.module_upgrade_item ui
         set payload = jsonb_set(ui.payload, '{transitions}', (ui.payload -> 'transitions')
               || jsonb_build_array(jsonb_build_object('code', 'zz_reseed_shipped', 'name', 'Shipped', 'from', 'draft', 'to', 'approved')))
       where ui.install_code = 'procurement-lifecycle' and ui.to_version = 2
         and ui.object_kind = 'state_machine' and ui.object_key = 'purchase_order';
      v_reg := erp.transition_driver_register() || jsonb_build_array(
        jsonb_build_object('machine_code', 'purchase_order', 'transition_code', 'zz_reseed_shipped', 'driver', 'screen', 'detail', ''),
        jsonb_build_object('machine_code', 'purchase_order', 'transition_code', 'zz_reseed_unshipped', 'driver', 'screen', 'detail', ''));
      select count(*) filter (where u.reference = 'purchase_order.zz_reseed_shipped'),
             count(*) filter (where u.reference = 'purchase_order.zz_reseed_unshipped'
                                and u.finding = 'a registered transition the lifecycle does not declare')
        into v_n, v_n2
        from erp.undriven_transition_report(v_reg) u;
      v_n3 := (select count(*) from erp.transition t where t.code = 'zz_reseed_shipped');
      v_ok := v_n = 0 and v_n2 = 1 and v_n3 = 0;
      v_msg := format('shipped and held by nobody (%s held): %s finding(s); a code nothing ships: %s finding(s)', v_n3, v_n, v_n2);
      raise exception using message = v_undo;
    exception when others then
      if sqlerrm <> v_undo then v_ok := false; v_msg := 'the block refused: ' || left(sqlerrm, 200); end if;
    end;
    return query select v_names[8], coalesce(v_ok, false), v_msg; v_step := 8;

    -- ── 9 ────────────────────────────────────────────────────────────────
    v_ok := null; v_msg := null;
    begin
      insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
      values ('procurement-lifecycle', 1, 'state_machine', 'purchase_order',
              jsonb_build_object('code', 'purchase_order', 'object_type', 'document',
                'transitions', jsonb_build_array(jsonb_build_object('code', 'zz_reseed_older', 'from', 'draft', 'to', 'approved'))),
              999);
      v_reg := erp.transition_driver_register() || jsonb_build_array(
        jsonb_build_object('machine_code', 'purchase_order', 'transition_code', 'zz_reseed_older', 'driver', 'screen', 'detail', ''),
        jsonb_build_object('machine_code', 'goods_receipt', 'transition_code', 'inherit_approval', 'driver', 'screen', 'detail', ''));
      select count(*) filter (where u.reference = 'purchase_order.zz_reseed_older'
                                and u.finding = 'a registered transition the lifecycle does not declare'),
             count(*) filter (where u.reference = 'goods_receipt.inherit_approval'
                                and u.finding = 'a registered transition the lifecycle does not declare')
        into v_n, v_n2
        from erp.undriven_transition_report(v_reg) u;
      v_ok := v_n = 1 and v_n2 = 1;
      v_msg := format('a code only the version 1 payload declares: %s finding(s); purchase_order''s code under goods_receipt: %s finding(s)', v_n, v_n2);
      raise exception using message = v_undo;
    exception when others then
      if sqlerrm <> v_undo then v_ok := false; v_msg := 'the block refused: ' || left(sqlerrm, 200); end if;
    end;
    return query select v_names[9], coalesce(v_ok, false), v_msg; v_step := 9;

    -- ── 10 ───────────────────────────────────────────────────────────────
    -- Organisation F: a fresh install at version 2, at the defaults.
    select coalesce(jsonb_object_agg(m.object_kind || '.' || m.object_key,
                      m.content - 'version' - 'effective_from' - 'effective_to'), '{}'::jsonb)
      into v_a
      from erp.configuration_manifest(array['state_machine', 'approval_chain', 'document_type']) m
     where (m.object_kind, m.object_key) in (('state_machine','requisition'), ('state_machine','purchase_order'),
                                             ('approval_chain','requisition_value'), ('document_type','requisition'));
    select * into r from erp.provision_tenant('zzrsf', 'Reseed Suite F', 'admin@zzrsf.test', 'Reseed Admin F');
    tf := r.tenant_id;
    perform set_config('request.jwt.claims', json_build_object('sub', a_f)::text, true);
    perform erp.claim_invitation(r.admin_token);
    update erp.environment set is_live = false where tenant_id = tf and is_self;
    perform erp.configure_finance(extract(year from current_date)::integer, null);
    perform erp.configure_procurement();
    select coalesce(jsonb_object_agg(m.object_kind || '.' || m.object_key,
                      m.content - 'version' - 'effective_from' - 'effective_to'), '{}'::jsonb)
      into v_f
      from erp.configuration_manifest(array['state_machine', 'approval_chain', 'document_type']) m
     where (m.object_kind, m.object_key) in (('state_machine','requisition'), ('state_machine','purchase_order'),
                                             ('approval_chain','requisition_value'), ('document_type','requisition'));
    v_ok := v_a = v_f and (select count(*) from jsonb_object_keys(v_a)) = 4
      and (select i.installer_version from erp.module_installation i
            where i.tenant_id = tf and i.install_code = 'procurement-lifecycle') = 2;
    select coalesce(string_agg(k, ', '), 'none') into v_msg
      from (select k from jsonb_object_keys(v_a || v_f) k
             where v_a -> k is distinct from v_f -> k) d;
    return query select v_names[10], coalesce(v_ok, false),
      format('%s object(s) compared; differing: %s', (select count(*) from jsonb_object_keys(v_a)), v_msg); v_step := 10;

    -- ── 11 ───────────────────────────────────────────────────────────────
    perform set_config('request.jwt.claims', json_build_object('sub', a_a)::text, true);
    v_doc := erp.rollback_to_snapshot(
      (select cs.rollback_snapshot_id from erp.change_set cs where cs.tenant_id = ta and cs.id = a_cs),
      'The reseed suite rehearses the reversal of version 2');
    v_doc2 := erp.open_document('purchase_order', v_sup, v_ent, v_site);
    perform erp.add_document_line(v_doc2, v_item, 1, 1000, 'raised after the rollback');
    v_st := erp.transition_document(a_po_born, 'send');
    select os.state_machine_version_id into v_line from erp.object_state os
     where os.tenant_id = ta and os.object_type = 'document' and os.object_id = v_doc2;
    v_ok := (select cs.status from erp.change_set cs where cs.tenant_id = ta and cs.id = v_doc) = 'rolled_back'
      and v_line not in (a_po_v1, a_po_v2)
      -- The new order runs exactly v1's moves.
      and (select array_agg(t.code order by t.code) from erp.transition t where t.state_machine_version_id = v_line)
          = (select array_agg(t.code order by t.code) from erp.transition t where t.state_machine_version_id = a_po_v1)
      and (select dt.approval_chain_code from erp.document_type dt where dt.tenant_id = ta and dt.code = 'requisition') is null
      and v_st = 'sent'
      and (select os.state_machine_version_id from erp.object_state os
            where os.tenant_id = ta and os.object_type = 'document' and os.object_id = a_po_born) = a_po_v2
      and (select os.state_machine_version_id from erp.object_state os
            where os.tenant_id = ta and os.object_type = 'document' and os.object_id = a_rq_new) = a_req_v2;
    v_msg := format('new order on v%s (inherit_approval: %s), requisition chain %s; the born order issued on v2: %s; installation still reads v%s, plan %s item(s)',
                    (select v.version from erp.state_machine_version v where v.id = v_line),
                    exists (select 1 from erp.transition t where t.state_machine_version_id = v_line and t.code = 'inherit_approval'),
                    coalesce((select dt.approval_chain_code from erp.document_type dt where dt.tenant_id = ta and dt.code = 'requisition'), 'none'),
                    v_st,
                    (select i.installer_version from erp.module_installation i where i.tenant_id = ta and i.install_code = 'procurement-lifecycle'),
                    (select count(*) from erp.plan_module_upgrade('procurement-lifecycle')));
    return query select v_names[11], coalesce(v_ok, false), v_msg; v_step := 11;

    -- ═════════════════════════════════════════════════════════════════════
    -- Organisation B: v1 with approver 'purchasing' and threshold 500000
    -- ═════════════════════════════════════════════════════════════════════
    select * into r from erp.provision_tenant('zzrsb', 'Reseed Suite B', 'admin@zzrsb.test', 'Reseed Admin B');
    tb := r.tenant_id;
    perform set_config('request.jwt.claims', json_build_object('sub', a_b)::text, true);
    perform erp.claim_invitation(r.admin_token);
    update erp.environment set is_live = false where tenant_id = tb and is_self;
    perform erp.configure_finance(extract(year from current_date)::integer, null);
    select e.code into v_ent_code from erp.entity e where e.tenant_id = tb and e.id = r.entity_id;
    perform erp.install_module_config('procurement-lifecycle', 'Procurement lifecycle',
      'Version 1, customised', erp_test.procurement_lifecycle_v1_items(v_ent_code, 500000, 'purchasing'));
    update erp.module_installation set installer_version = 1
     where tenant_id = tb and install_code = 'procurement-lifecycle';

    -- ── 12 ───────────────────────────────────────────────────────────────
    res := erp.upgrade_module_configuration('procurement-lifecycle');
    select m.content into v_a from erp.configuration_manifest(array['approval_chain']) m where m.object_key = 'purchase_order_value';
    select m.content into v_f from erp.configuration_manifest(array['approval_chain']) m where m.object_key = 'requisition_value';
    v_ok := (res ->> 'promoted')::boolean
      and (select bool_and(s ->> 'role' = 'purchasing') from jsonb_array_elements(v_a -> 'steps') s)
      and (select s -> 'condition' from jsonb_array_elements(v_a -> 'steps') s where s ->> 'code' = 'finance')
          = jsonb_build_object('>', jsonb_build_array(jsonb_build_object('var', 'total_minor'), 500000))
      and (select bool_and(s ->> 'role' = 'administrator') from jsonb_array_elements(v_f -> 'steps') s)
      and (select s -> 'condition' from jsonb_array_elements(v_f -> 'steps') s where s ->> 'code' = 'finance')
          = jsonb_build_object('>', jsonb_build_array(jsonb_build_object('var', 'total_minor'), 1000000))
      and (select dt.approval_chain_code from erp.document_type dt where dt.tenant_id = tb and dt.code = 'purchase_order') = 'purchase_order_value'
      and (select dt.approval_chain_code from erp.document_type dt where dt.tenant_id = tb and dt.code = 'requisition') = 'requisition_value';
    v_msg := format('order chain roles %s over %s; requisition chain roles %s over %s',
                    (select string_agg(distinct s ->> 'role', ',') from jsonb_array_elements(v_a -> 'steps') s),
                    (select s -> 'condition' -> '>' -> 1 from jsonb_array_elements(v_a -> 'steps') s where s ->> 'code' = 'finance'),
                    (select string_agg(distinct s ->> 'role', ',') from jsonb_array_elements(v_f -> 'steps') s),
                    (select s -> 'condition' -> '>' -> 1 from jsonb_array_elements(v_f -> 'steps') s where s ->> 'code' = 'finance'));
    return query select v_names[12], coalesce(v_ok, false), v_msg; v_step := 12;

    -- ═════════════════════════════════════════════════════════════════════
    -- Organisation D: a demonstration, not live, on v1
    -- ═════════════════════════════════════════════════════════════════════
    select * into r from erp.provision_tenant('demo-zzreseed', 'Reseed Suite Demonstration', 'admin@demo-zzreseed.test', 'Reseed Admin D');
    td := r.tenant_id;
    perform set_config('request.jwt.claims', json_build_object('sub', a_d)::text, true);
    perform erp.claim_invitation(r.admin_token);
    update erp.environment set is_live = false where tenant_id = td and is_self;
    perform erp.configure_finance(extract(year from current_date)::integer, null);
    select e.code into v_ent_code from erp.entity e where e.tenant_id = td and e.id = r.entity_id;
    perform erp.install_module_config('procurement-lifecycle', 'Procurement lifecycle',
      'Version 1, as a demonstration installed it', erp_test.procurement_lifecycle_v1_items(v_ent_code));
    update erp.module_installation set installer_version = 1
     where tenant_id = td and install_code = 'procurement-lifecycle';
    perform erp.ensure_demo_configuration(td, r.admin_user_id);

    -- ── 14, run first, while D is on v1 ──────────────────────────────────
    -- A faulty item joins version 2 inside this block, which is rolled back.
    begin
      insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
      values ('procurement-lifecycle', 2, 'document_type', 'zz_reseed_faulty',
              jsonb_build_object('code', 'zz_reseed_faulty', 'base_type', 'zz_no_such_base', 'name', 'Faulty',
                                 'state_machine', 'zz_no_such_machine', 'numbering_rule', 'zz_no_such_rule'),
              140);
      res := erp.demonstration_catch_up();
      v_ok14 := exists (select 1 from jsonb_array_elements_text(res -> 'notes') n
                         where n like 'The procurement lifecycle was not upgraded, so it trades on the version it has: %')
        and not exists (select 1 from jsonb_array_elements_text(res -> 'notes') n
                         where n like 'The procurement lifecycle was upgraded%')
        and res ? 'periods_closed'
        and (select i.installer_version from erp.module_installation i
              where i.tenant_id = td and i.install_code = 'procurement-lifecycle') = 1
        and not exists (select 1 from erp.state_machine m join erp.state_machine_version v on v.state_machine_id = m.id
                         where m.tenant_id = td and m.code in ('requisition', 'purchase_order') and v.version > 1)
        and not exists (select 1 from erp.change_set cs where cs.tenant_id = td and cs.code like 'procurement-lifecycle-upgrade-%');
      v_msg14 := format('notes %s; installation v%s', res -> 'notes',
                        (select i.installer_version from erp.module_installation i
                          where i.tenant_id = td and i.install_code = 'procurement-lifecycle'));
      raise exception using message = v_undo;
    exception when others then
      if sqlerrm <> v_undo then v_ok14 := false; v_msg14 := 'the block refused: ' || left(sqlerrm, 200); end if;
    end;
    v_ok14 := v_ok14 and (select count(*) from erp_ref.module_upgrade_item ui
                           where ui.install_code = 'procurement-lifecycle' and ui.to_version = 2) = 4;

    -- ── 13 ───────────────────────────────────────────────────────────────
    res := erp.demonstration_catch_up();
    res2 := erp.demonstration_catch_up();
    v_ok := exists (select 1 from jsonb_array_elements_text(res -> 'notes') n
                     where n = 'The procurement lifecycle was upgraded to version 2.')
      and not exists (select 1 from jsonb_array_elements_text(res2 -> 'notes') n where n like 'The procurement lifecycle%')
      and (select count(*) from erp.plan_module_upgrade('procurement-lifecycle')) = 0
      and (select i.installer_version from erp.module_installation i
            where i.tenant_id = td and i.install_code = 'procurement-lifecycle') = 2
      and (select count(*) from erp.change_set cs where cs.tenant_id = td and cs.code like 'procurement-lifecycle-upgrade-%') = 1
      and (select count(*) from erp.state_machine m join erp.state_machine_version v on v.state_machine_id = m.id
            where m.tenant_id = td and m.code in ('requisition', 'purchase_order') and v.version = 2 and v.status = 'active') = 2;
    v_msg := format('first run %s; second run %s', res -> 'notes', res2 -> 'notes');
    return query select v_names[13], coalesce(v_ok, false), v_msg; v_step := 13;
    return query select v_names[14], coalesce(v_ok14, false), v_msg14; v_step := 14;

    -- ═════════════════════════════════════════════════════════════════════
    -- Organisation C: live, two administrators, v1 backdated
    -- ═════════════════════════════════════════════════════════════════════
    select * into r from erp.provision_tenant('zzrsc', 'Reseed Suite C', 'admin@zzrsc.test', 'Reseed Admin C');
    tc := r.tenant_id; v_ent := r.entity_id;
    perform set_config('request.jwt.claims', json_build_object('sub', a_c)::text, true);
    perform erp.claim_invitation(r.admin_token);
    update erp.environment set is_live = false where tenant_id = tc and is_self;
    select i.app_user_id, i.token into u_c2, v_tok from erp.invite_principal('second@zzrsc.test', 'Second Admin C') i;
    perform erp.grant_role(u_c2, 'administrator', null, null, 'the reseed suite: a second administrator', null, null, null);
    perform set_config('request.jwt.claims', json_build_object('sub', a_c2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform set_config('request.jwt.claims', json_build_object('sub', a_c)::text, true);
    perform erp.configure_finance(extract(year from current_date)::integer, null);
    select e.code into v_ent_code from erp.entity e where e.tenant_id = tc and e.id = v_ent;
    perform erp.install_module_config('procurement-lifecycle', 'Procurement lifecycle',
      'Version 1, as a customer installed it', erp_test.procurement_lifecycle_v1_items(v_ent_code));
    update erp.module_installation
       set installer_version = 1, installed_at = now() - interval '30 days'
     where tenant_id = tc and install_code = 'procurement-lifecycle';
    res := erp.ensure_demo_configuration(tc, r.admin_user_id);
    v_site := (res ->> 'site_id')::uuid;
    update erp.state_machine_version v set effective_from = current_date - 30
      from erp.state_machine m
     where m.tenant_id = tc and m.id = v.state_machine_id and v.tenant_id = tc
       and m.code in ('purchase_order', 'requisition');
    select v.id into c_req_v1 from erp.state_machine_version v join erp.state_machine m on m.id = v.state_machine_id
     where m.tenant_id = tc and m.code = 'requisition' and v.version = 1;
    select v.id into c_po_v1 from erp.state_machine_version v join erp.state_machine m on m.id = v.state_machine_id
     where m.tenant_id = tc and m.code = 'purchase_order' and v.version = 1;
    select it.id into v_item from erp.item it where it.tenant_id = tc and it.status = 'active' order by it.code limit 1;
    select p.id into v_sup from erp.party p
      join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id and pr.role_kind = 'supplier'
     where p.tenant_id = tc and p.status = 'active' order by p.code limit 1;
    -- In flight on v1, seeded before it went live.
    c_rq_sub := erp.open_document('requisition', v_sup, v_ent, v_site);
    perform erp.add_document_line(c_rq_sub, v_item, 3, 1000, 'v1 submitted');
    perform erp.transition_document(c_rq_sub, 'submit');
    c_po_app := erp.open_document('purchase_order', v_sup, v_ent, v_site);
    perform erp.add_document_line(c_po_app, v_item, 10, 1000, 'v1 order approved');
    perform erp.transition_document(c_po_app, 'submit');
    perform erp_test.approve_document(c_po_app, 'the reseed suite');
    c_po_recv := erp.open_document('purchase_order', v_sup, v_ent, v_site);
    c_pl_recv := erp.add_document_line(c_po_recv, v_item, 10, 1000, 'v1 order received');
    perform erp.transition_document(c_po_recv, 'submit');
    perform erp_test.approve_document(c_po_recv, 'the reseed suite');
    perform erp.transition_document(c_po_recv, 'send');
    v_g := erp.open_document('goods_receipt', v_sup, v_ent, v_site);
    perform erp.receive_against(v_g, c_pl_recv, 10, null);
    perform erp.transition_document(v_g, 'post');
    update erp.environment set is_live = true where tenant_id = tc and is_self;
    -- A change needs a second person here, as a customer's would.
    perform erp_test.administrator_approval_off(tc);

    -- ── 15 ───────────────────────────────────────────────────────────────
    res := erp.upgrade_module_configuration('procurement-lifecycle');
    c_cs := (res ->> 'change_set_id')::uuid;
    begin
      perform erp.approve_change_set(c_cs);
      v_err := 'its author approved it';
    exception when others then
      v_err := sqlerrm;
    end;
    v_ok := erp.tenant_is_live(tc)
      and not (res ->> 'promoted')::boolean and (res ->> 'items')::integer = 4
      and (select cs.status::text from erp.change_set cs where cs.tenant_id = tc and cs.id = c_cs) = 'ready'
      and (select i.installer_version = 1 and i.pending_change_set_id = c_cs
             from erp.module_installation i where i.tenant_id = tc and i.install_code = 'procurement-lifecycle')
      and not exists (select 1 from erp.state_machine m join erp.state_machine_version v on v.state_machine_id = m.id
                       where m.tenant_id = tc and m.code in ('requisition', 'purchase_order') and v.version > 1)
      and v_err like 'CLOVEERP_CHANGE_SET_SELF_APPROVAL:%';
    v_msg := format('%s; change set %s; its author: %s', res - 'change_set_id',
                    (select cs.status::text from erp.change_set cs where cs.tenant_id = tc and cs.id = c_cs), left(v_err, 90));
    return query select v_names[15], coalesce(v_ok, false), v_msg; v_step := 15;

    -- ── 16 ───────────────────────────────────────────────────────────────
    perform set_config('request.jwt.claims', json_build_object('sub', a_c2)::text, true);
    perform erp.approve_change_set(c_cs);
    perform erp.promote_change_set(c_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a_c)::text, true);
    select * into x from erp.module_installations() mi where mi.install_code = 'procurement-lifecycle';
    v_ok := (select cs.status::text from erp.change_set cs where cs.tenant_id = tc and cs.id = c_cs) = 'promoted'
      and (select i.installer_version = 2 and i.pending_change_set_id is null and i.change_set_id = c_cs
             from erp.module_installation i where i.tenant_id = tc and i.install_code = 'procurement-lifecycle')
      and x.installer_version = 2 and x.current_version = 2 and not x.upgrade_available
      and (select count(*) from erp.state_machine m join erp.state_machine_version v on v.state_machine_id = m.id
            where m.tenant_id = tc and m.code in ('requisition', 'purchase_order') and v.version = 2
              and v.status = 'active' and v.effective_from = current_date) = 2
      and (select count(*) from erp.plan_module_upgrade('procurement-lifecycle')) = 0;
    v_msg := format('installation v%s of v%s, upgrade available %s, pending %s',
                    x.installer_version, x.current_version, x.upgrade_available, coalesce(x.pending_change_set_id::text, 'none'));
    return query select v_names[16], coalesce(v_ok, false), v_msg; v_step := 16;

    -- ── 17 ───────────────────────────────────────────────────────────────
    v_st := erp.transition_document(c_po_app, 'send');
    v_st2 := erp.transition_document(c_rq_sub, 'approve');
    v_bill := erp.open_document('purchase_invoice', v_sup, v_ent, v_site);
    perform erp.invoice_against(v_bill, c_pl_recv, 10, 1000);
    update erp.document set their_reference = 'ZZRS-C-1', due_date = current_date + 30
     where tenant_id = tc and id = v_bill;
    perform erp.transition_document(v_bill, 'register');
    v_ok := v_st = 'sent' and v_st2 = 'approved'
      and erp.object_current_state('document', c_po_recv) = 'closed'
      and not exists (select 1 from erp.approval_request q where q.tenant_id = tc and q.object_id = c_rq_sub)
      and not exists (select 1 from erp.object_state os
                       where os.tenant_id = tc and os.object_type = 'document'
                         and os.object_id in (c_po_app, c_po_recv) and os.state_machine_version_id <> c_po_v1)
      and (select os.state_machine_version_id from erp.object_state os
            where os.tenant_id = tc and os.object_type = 'document' and os.object_id = c_rq_sub) = c_req_v1;
    v_msg := format('approved order %s, submitted requisition %s on its permission, received order %s on its bill; all on v1: %s',
                    v_st, v_st2, erp.object_current_state('document', c_po_recv),
                    not exists (select 1 from erp.object_state os
                                 where os.tenant_id = tc and os.object_type = 'document'
                                   and os.object_id in (c_po_app, c_po_recv, c_rq_sub)
                                   and os.state_machine_version_id not in (c_po_v1, c_req_v1)));
    return query select v_names[17], coalesce(v_ok, false), v_msg; v_step := 17;

    -- ── 18 ───────────────────────────────────────────────────────────────
    -- D2 is about the administrator override, which is on by default: back on.
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', tc::text, true);
    perform erp_test.reopen_bootstrap_window(tc);
    perform erp.set_config_value('approval.administrator_override', '{"allowed": true}'::jsonb,
                                 null, null, null, null, 'the reseed suite: D2 is decided with the override on');
    perform erp_test.close_bootstrap_window(tc);
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', a_c)::text, true);

    -- a. Raised, and approved, by the same administrator.
    v_doc := erp.open_document('requisition', v_sup, v_ent, v_site);
    perform erp.add_document_line(v_doc, v_item, 2, 1000, 'own approval');
    perform erp.transition_document(v_doc, 'submit');
    v_st := erp.transition_document(v_doc, 'approve');
    res := erp.convert_document(v_doc, null, null, null, null);
    v_n := (select count(*) from erp.event ev
              join erp.approval_request q on q.tenant_id = ev.tenant_id and q.id = ev.aggregate_id
             where ev.tenant_id = tc and q.object_id = v_doc
               and ev.event_type = 'approval.administrator_decided'
               and coalesce((ev.payload ->> 'own_request')::boolean, false));
    -- b. Raised by one administrator, decided by the other.
    v_doc2 := erp.open_document('requisition', v_sup, v_ent, v_site);
    perform erp.add_document_line(v_doc2, v_item, 2, 1000, 'decided by another');
    perform erp.transition_document(v_doc2, 'submit');
    perform set_config('request.jwt.claims', json_build_object('sub', a_c2)::text, true);
    for x in select tk.id from erp.approval_task tk
               join erp.approval_request q on q.tenant_id = tk.tenant_id and q.id = tk.approval_request_id
              where tk.tenant_id = tc and q.object_id = v_doc2 and q.status = 'pending' and tk.status = 'pending'
              order by tk.seq
    loop
      perform erp.decide_approval_task(x.id, true, 'the reseed suite');
    end loop;
    v_st2 := erp.transition_document(v_doc2, 'approve');
    perform set_config('request.jwt.claims', json_build_object('sub', a_c)::text, true);
    res2 := erp.convert_document(v_doc2, null, null, null, null);
    v_ok := v_st = 'approved' and v_n >= 1
      and not (res ->> 'born_approved')::boolean
      and res ->> 'approval_not_carried' = 'approved_by_its_requester'
      and erp.object_current_state('document', (res ->> 'document_id')::uuid) = 'draft'
      and v_st2 = 'approved'
      and (res2 ->> 'born_approved')::boolean
      and erp.object_current_state('document', (res2 ->> 'document_id')::uuid) = 'approved';
    v_msg := format('own approval (%s override decision(s)): born %s (%s), order %s; decided by the other: born %s, order %s',
                    v_n, res ->> 'born_approved', coalesce(res ->> 'approval_not_carried', 'carried'),
                    erp.object_current_state('document', (res ->> 'document_id')::uuid),
                    res2 ->> 'born_approved', erp.object_current_state('document', (res2 ->> 'document_id')::uuid));
    return query select v_names[18], coalesce(v_ok, false), v_msg; v_step := 18;

    -- ═════════════════════════════════════════════════════════════════════
    -- Each organisation purged. Journals are checked by deferred triggers,
    -- fired here against data that still exists.
    -- ═════════════════════════════════════════════════════════════════════
    set constraints all immediate;
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', '', true);
    foreach v_doc in array array[ta, tf, tb, td, tc] loop
      if v_doc is not null then
        perform erp.begin_tenant_purge(v_doc);
        delete from erp.tenant where id = v_doc;
        perform erp.end_tenant_purge();
      end if;
    end loop;
  exception when others then
    -- Everything the suite did is rolled back with the block; each case it
    -- did not reach is reported, the first with the refusal.
    v_err := left(sqlerrm, 300);
    if v_step = 18 then v_purge_err := v_err; end if;
    for i in v_step + 1 .. 18 loop
      return query select v_names[i], false,
        case when i = v_step + 1 then 'the suite stopped here: ' || v_err else 'not reached' end;
    end loop;
  end;

  -- ── 19 ─────────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);
  select count(*) into v_n from erp.tenant tn where tn.code = any (v_codes);
  select count(*) into v_n2 from erp_ref.module_upgrade_item ui
    join jsonb_array_elements(erp.procurement_lifecycle_items(null, 1000000, 'administrator')) it
      on it.value ->> 'kind' = ui.object_kind and it.value ->> 'key' = ui.object_key
     and (it.value -> 'payload') - 'entity' = ui.payload
   where ui.install_code = 'procurement-lifecycle' and ui.to_version = 2;
  select count(*) into v_n3 from erp_ref.module_upgrade_item ui
   where ui.install_code = 'procurement-lifecycle';
  return query select v_names[19],
    v_purge_err is null and v_n = 0 and v_n2 = 4 and v_n3 = 4
    and (select count(*) from erp_ref.module_upgrade_item) = v_items_before
    and coalesce(current_setting('erp.carrying_approval', true), '') = ''
    and coalesce(current_setting('erp.deriving_move', true), '') = '',
    coalesce('the purge refused, and the rollback took everything: ' || v_purge_err || '; ', '') ||
    format('%s organisation(s) left; %s of the procurement lifecycle''s %s upgrade row(s) are version 2''s own; %s upgrade row(s), %s before',
           v_n, v_n2, v_n3, (select count(*) from erp_ref.module_upgrade_item), v_items_before);
end;
$$;

comment on function erp_test.procurement_reseed_suite() is
  'An organisation on version 1 of the procurement lifecycle takes version 2 '
  '(20260922380000): through Upgrade when not live, through a second '
  'administrator when live, through the demonstration catch-up for a '
  'demonstration, and back through the promotion''s snapshot. Nineteen cases.';

create or replace function erp_test.assert_procurement_reseed_suite()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_failed integer; v_total integer; v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail from erp_test.procurement_reseed_suite() s;
  if v_total <> 19 then
    raise exception 'CLOVEERP_PROCUREMENT_RESEED_SUITE_SHRANK: % case(s), expected 19', v_total
      using hint = 'erp_test.procurement_reseed_suite() proves an organisation on version 1 of the procurement lifecycle reaches version 2 in nineteen cases; one went missing or one was added without this count.';
  end if;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PROCUREMENT_RESEED_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Run select * from erp_test.procurement_reseed_suite() for every case. An organisation on version 1 no longer reaches version 2 as 20260922380000 says it does.';
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
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
