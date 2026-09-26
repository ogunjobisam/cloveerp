set lock_timeout = '30s';

-- =============================================================================
-- 20260928500000  A stock adjustment is approved by what it is worth
-- -----------------------------------------------------------------------------
-- PR11, M4 and M5 folded into one (docs/spec/simplification-review.md §7,
-- node I5 for the stock adjustment, and PR10's follow-ups (a), (b) and (f)):
-- version 2 of the stock adjustment's lifecycle and version 2 of the count
-- task's, delivered to an organisation already live as version 9 of
-- inventory-operations through the upgrade register, to a demonstration
-- through its catch-up, and to a new organisation at install. Decisions D9
-- to D14 as taken on 25 September, and D10 as taken on 26 September.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- On a database built from main (PR11 scoping, E2 and E3):
--
--   * One person raised, approved and posted a stock adjustment of any size.
--     A chain named on the type was never asked: the lifecycle had no submit.
--   * THEFT_LOSS and SYSTEM_CORRECTION say they require approval, and nothing
--     read it: erp.check_reason_code() answered and the raise discarded it.
--   * A COUNT_VARIANCE could be typed by hand, so a count's name was put on a
--     write-down no count had made, past the self-posting rule (a).
--   * A count's adjustment was approved by the lifecycle's own approve from
--     draft, which is also the move a person makes (b).
--   * erp.write_off_stock(), the Stock strip's "Correct", wrote a scrap
--     movement in one press, with no document and no approval.
--   * An approved adjustment, or one waiting, could be amended or take a new
--     line and keep its approval.
--   * A count whose post was refused for good stayed approved for ever: its
--     only way out was the post that failed (f).
--
-- ── WHAT VERSION 2 OF THE STOCK ADJUSTMENT'S LIFECYCLE IS ────────────────────
--
--   draft            → pending_approval  submit (asks for the approval)
--   pending_approval → approved          approve, by somebody the chain asked
--   pending_approval → approved          approve_within_threshold: derived, when
--                                        the approval asked nobody
--   pending_approval → draft             reject
--   draft            → approved          approve_with_count: derived from the
--                                        count's own approval (D9, answers b)
--   approved         → posted            post: its door's, derived from the
--                                        approval (D13)
--   draft            → cancelled         cancel
--   approved         → cancelled         cancel_approved (M1 refuses it once
--                                        stock has moved)
--
-- Every move asks inventory.adjust.
--
--   * The chain, stock_adjustment_value, reads value_at_cost_minor, which
--     20260928200000 put in the context: every line's quantity, either way,
--     at the site's unit cost. Its one step asks the inventory role, and its
--     condition is `false`: no adjustment needs anybody's approval until the
--     organisation sets its threshold (D10, 26 September), by proposing the
--     chain again with the step's condition
--     {">": [{"var": "value_at_cost_minor"}, <minor units>]}. An organisation
--     already live sees no new step.
--   * A reason the register says requires approval is worth more than any
--     threshold clears, as stock with no cost is: with no threshold set it
--     asks nobody, and once one is set it always asks. That is the reading of
--     D10 that changes nothing for an organisation that set nothing.
--   * Raising submits. When the approval asked nobody the adjustment is
--     approved within its threshold, and posted, in the same press (D13).
--     Otherwise it waits for the people the chain asked; the one who raised
--     it is refused by the engine in a live organisation, and the approver's
--     approve posts it. Decided under My approvals, it moves with the
--     decision, as a transfer order does.
--   * A count's adjustment inherits the count's approval (D9): it is approved
--     by approve_with_count, derived from erp.count_task_is_approved(), and
--     never meets the value chain. A count inside its tolerance posts as it
--     always did. approve_with_count pressed by anybody else is refused.
--   * COUNT_VARIANCE is the count's: erp.raise_stock_adjustment() refuses it
--     (CLOVEERP_COUNT_VARIANCE_IS_A_COUNTS, D11). The demonstration's Saturday
--     write-down is a damaged unit, DAMAGE_STORAGE, rather than a count
--     nobody made: its date is a past Saturday, and a real count is counted
--     today.
--   * erp.write_off_stock() keeps its signature and asks inventory.write_off
--     as it always did, and writes a stock adjustment under
--     EXPIRY_WRITE_OFF, the register's code for stock written off, with the
--     person's words as its note (D12). Its submit is the door's, so the
--     write-off asks nothing more of the person; the threshold then applies
--     to it as to any adjustment, and one over it waits and returns no
--     movement. Its movement is still a scrap at what the stock cost, with
--     the person's words on it, so the ledger reads as it did. An
--     organisation with no stock adjustment type writes off as before.
--   * An adjustment submitted, or approved, is not amended, takes no new line
--     and no stock pinned to a line (D6); one whose lines changed since its
--     approval was asked for is not approved (20260928200000 already).
--
-- ── WHAT VERSION 2 OF THE COUNT TASK'S LIFECYCLE IS ──────────────────────────
--
-- Version 1 and one move: cancel_approved, approved → cancelled, asking
-- inventory.adjust and a reason, through erp.cancel_count_task(). Only a
-- count whose post was refused (post_held_reason 'post_refused: …') or that
-- is held because its stock status is not known ('status_unknown: …'), with
-- no adjustment and nothing posted (D14). Its lock is released and its sheet
-- closes with it, as for any cancelled count. The worklist offers Cancel on
-- exactly those rows.
--
-- ── WHAT CHANGES FOR DOCUMENTS IN FLIGHT ─────────────────────────────────────
--
-- Nothing moves on its own. A version 1 adjustment is approved by its click
-- from draft and posted by Confirm, as before, and is not posted on approval.
-- Two things reach it: it is not amended or given a line once approved, and
-- COUNT_VARIANCE is refused at every raise. A count task raised on version 1
-- of its lifecycle has no cancel_approved; the door says so.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * No Approve or Reject on the adjustments screen: that is M6. The
--     document page and My approvals both decide it.
--   * An approved count raised on version 1 of the count task's lifecycle
--     is not carried onto version 2 to be cancelled: that would move its
--     state outside the engine (erp_test.assert_no_state_side_doors).
--   * The finance.post a backdated adjustment asks is asked of whoever raises
--     it; its approver's approve posts it on that date without asking again.
--     Nothing changes a stock adjustment's date once it is raised.
--   * No public function, so no allowance and no door.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The refusals this adds
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_COUNT_VARIANCE_IS_A_COUNTS',
  'Raising a stock adjustment by hand under the reason COUNT_VARIANCE.',
  'A count variance is what a count found. Typed by hand it would carry a count''s name on a write-down no count made, past the rule that somebody else posts a counter''s own difference.',
  'Count the place from the Counting worklist, and its variance is posted as its own adjustment. If the stock changed for another reason, pick that reason.');

select erp.register_refusal('CLOVEERP_ADJUSTMENT_AWAITS_APPROVAL',
  'Approving a stock adjustment within its threshold while somebody has been asked to approve it.',
  'An adjustment is approved within its threshold only when its value asked nobody. Once somebody has been asked, it waits for their decision, so a large write-off cannot be waved through by the person who raised it.',
  'Ask the people named under My approvals to decide it. The adjustment is posted, or sent back to draft, as they decide.');

select erp.register_refusal('CLOVEERP_ADJUSTMENT_APPROVED_WITH_ITS_COUNT',
  'Approving a stock adjustment with a count''s approval when it is not that count''s variance.',
  'Only the adjustment a count raised for its own variance carries the count''s approval. Any other adjustment is approved for what it is worth.',
  'Submit the adjustment for approval. Below the organisation''s threshold it is approved and posted as it is submitted.');

select erp.register_refusal('CLOVEERP_ADJUSTMENT_CHANGED_ONLY_AS_A_DRAFT',
  'Adding a line to a stock adjustment, or pinning stock to one of its lines, once it has been submitted.',
  'An adjustment is approved for what it says when it is submitted. A line added while it waits, or after, would be written off with an approval given for less.',
  'Have the adjustment rejected back to draft, change it there and submit it again, or raise a second adjustment for the rest.');

select erp.register_refusal('CLOVEERP_WRITE_OFF_NEEDS_A_QUANTITY',
  'Writing off nothing, or less than nothing.',
  'A write-off takes stock off the shelf. A quantity of nothing changes nothing, and a negative one would put stock on the shelf under the name of a loss.',
  'Say how many are lost as a positive number. Stock found is raised as a stock adjustment with a positive line.');

select erp.register_refusal('CLOVEERP_REJECT_IS_THE_APPROVERS',
  'Rejecting a transfer order or a stock adjustment that waits for somebody else''s approval, by a person its approval did not ask.',
  'A rejection is a decision on the approval, so it is the decision of the people the approval asked. The person who raised it may take it back to draft as a withdrawal. Anybody else who may move or adjust stock was never asked, and would otherwise overrule the approver.',
  'Leave it to the people named under My approvals, or ask the person who raised it to withdraw it.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. What the lifecycle's facts read
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.adjustment_is_past_draft(p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- A stock adjustment submitted and not yet finished (20260928500000):
  -- waiting for approval, or approved and not posted, on either version.
  -- What was approved is what is written off, so its lines are not changed:
  -- read by erp.amendment_allowed(), erp.add_document_line() and
  -- erp.set_line_stock_identity().
  select exists (
    select 1
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      join erp.object_state os
        on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      join erp.state s on s.id = os.current_state_id
     where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id
       and dt.base_type_code = 'adjustment'
       and not d.is_cancelled
       and not s.is_initial and not s.is_terminal)
$$;

revoke all on function erp.adjustment_is_past_draft(uuid) from public, anon;

comment on function erp.adjustment_is_past_draft(uuid) is
  'True for a stock adjustment submitted or approved and not yet posted or cancelled, whose lines are no '
  'longer changed (20260928500000).';

create or replace function erp.adjustment_is_approved(p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- A stock adjustment on version 2 of its lifecycle that stands approved,
  -- with no approval still waiting on anybody (20260928500000): the fact its
  -- post is derived from, read again by erp.derived_move_fact() with the
  -- adjustment's state locked. Version 2 is the version that declares
  -- approve_within_threshold; on version 1 an approved adjustment is posted
  -- by Confirm, as it always was. Every way into approved on version 2 is an
  -- approval: the chain's, nobody's being asked, or the count's.
  select exists (
    select 1
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      join erp.object_state os
        on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      join erp.state s on s.id = os.current_state_id
     where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id
       and dt.base_type_code = 'adjustment'
       and not d.is_cancelled
       and s.code = 'approved'
       and exists (select 1 from erp.transition t
                    where t.tenant_id = os.tenant_id
                      and t.state_machine_version_id = os.state_machine_version_id
                      and t.code = 'approve_within_threshold')
       and not exists (select 1 from erp.approval_request q
                        where q.tenant_id = d.tenant_id and q.object_type = 'document'
                          and q.object_id = d.id and q.status = 'pending'))
$$;

revoke all on function erp.adjustment_is_approved(uuid) from public, anon;

comment on function erp.adjustment_is_approved(uuid) is
  'True for a version 2 stock adjustment standing approved with no approval pending (20260928500000): '
  'the fact its post on approval is derived from.';

create or replace function erp.adjustment_reason_requires_approval(p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- Whether the reason a stock adjustment gives is one the organisation's
  -- register says requires approval (20260928500000): THEFT_LOSS and
  -- SYSTEM_CORRECTION as shipped. Read by erp.document_transition_context(),
  -- which then values the adjustment above any threshold. A reason the
  -- register does not keep requires nothing, as erp.check_reason_code() says.
  select coalesce((
    select rc.requires_approval
      from erp.document d
      join erp.reason_code rc
        on rc.tenant_id = d.tenant_id
       and rc.category_code = 'STOCK_ADJUSTMENT'
       and rc.code = upper(btrim(d.attributes ->> 'reason_code'))
       and rc.status = 'active'
     where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id
     limit 1), false)
$$;

revoke all on function erp.adjustment_reason_requires_approval(uuid) from public, anon;

comment on function erp.adjustment_reason_requires_approval(uuid) is
  'Whether a stock adjustment''s reason is one the register says requires approval (20260928500000).';

create or replace function erp.reject_refusal(p_document_id uuid)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.current_tenant_id();
  v_me     uuid := erp.current_principal_id();
  q        erp.approval_request%rowtype;
begin
  -- Why this person may not reject a transfer order or a stock adjustment
  -- waiting for approval, or null when they may (20260928500000, found by
  -- the PR11 M6 walk). A rejection is the decision of the people the
  -- pending request asks, as an approval is, which an administrator makes
  -- where the organisation lets administrators decide approvals; the person
  -- who asked may take it back to draft as a withdrawal. Nobody else, whatever
  -- they may move or adjust. Read by erp.transition_document(), which
  -- refuses the move, and by erp.transition_refusal(), so the screens do not
  -- draw it. Any other document, state or move: null.
  if v_tenant is null or not exists (
       select 1 from erp.document d
         join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
        where d.tenant_id = v_tenant and d.id = p_document_id
          and dt.base_type_code in ('transfer_order', 'adjustment'))
     or erp.object_current_state('document', p_document_id) is distinct from 'pending_approval' then
    return null;
  end if;

  select ar.* into q
    from erp.approval_request ar
   where ar.tenant_id = v_tenant and ar.object_type = 'document'
     and ar.object_id = p_document_id and ar.status = 'pending'
   order by ar.requested_at desc
   limit 1;
  -- Nobody is asked: nothing to overrule.
  if not found then
    return null;
  end if;

  if q.requested_by is not distinct from v_me
     or erp.approves_as_administrator()
     or exists (select 1 from erp.approval_task t
                 where t.tenant_id = v_tenant and t.approval_request_id = q.id
                   and t.status = 'pending' and t.assignee_user_id = v_me) then
    return null;
  end if;
  return 'CLOVEERP_REJECT_IS_THE_APPROVERS';
end;
$$;

revoke all on function erp.reject_refusal(uuid) from public, anon;

comment on function erp.reject_refusal(uuid) is
  'Why this person may not reject a transfer order or stock adjustment waiting for approval: only the '
  'approvers its pending request asks, an administrator where administrators decide approvals, and the '
  'person who asked, as a withdrawal (20260928500000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. The lifecycle, the chain and the document type, from one helper
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.stock_adjustment_pack_items()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- Version 2 of the stock adjustment (20260928500000), read by
  -- erp.configure_inventory() for a new install and by the upgrade register
  -- for an organisation on inventory-operations 8 or earlier, so the two
  -- cannot disagree. Every move asks inventory.adjust; the chain's one step
  -- applies to nothing until the organisation sets its threshold (D10).
  select jsonb_build_array(
    jsonb_build_object('kind', 'state_machine', 'key', 'stock_adjustment', 'payload',
      jsonb_build_object(
        'code', 'stock_adjustment', 'object_type', 'document', 'name', 'Stock adjustment',
        'states', jsonb_build_array(
          jsonb_build_object('code','draft','name','Draft','is_initial',true,'is_terminal',false,'is_committed',false,'sort_order',10),
          jsonb_build_object('code','pending_approval','name','Pending approval','is_initial',false,'is_terminal',false,'is_committed',false,'sort_order',15),
          jsonb_build_object('code','approved','name','Approved','is_initial',false,'is_terminal',false,'is_committed',true,'sort_order',20),
          jsonb_build_object('code','posted','name','Posted','is_initial',false,'is_terminal',true,'is_committed',true,'sort_order',30),
          jsonb_build_object('code','cancelled','name','Cancelled','is_initial',false,'is_terminal',true,'is_committed',false,'sort_order',510)),
        'transitions', jsonb_build_array(
          jsonb_build_object('code','submit','name','Submit','from','draft','to','pending_approval','required_permission','inventory.adjust','sort_order',5,
                             'effects',jsonb_build_array(jsonb_build_object('kind','require_approval'))),
          jsonb_build_object('code','approve','name','Approve','from','pending_approval','to','approved','required_permission','inventory.adjust','sort_order',10),
          -- Derived from erp.approval_asked_nobody(), asked for by
          -- erp.approve_adjustment_within_threshold() as the submit completes.
          jsonb_build_object('code','approve_within_threshold','name','Approve within threshold','from','pending_approval','to','approved','required_permission','inventory.adjust','is_automatic',true,'sort_order',12),
          jsonb_build_object('code','reject','name','Reject','from','pending_approval','to','draft','required_permission','inventory.adjust','sort_order',15),
          -- Derived from erp.count_task_is_approved(), asked for by
          -- erp.raise_count_adjustment(): the count's approval is the
          -- adjustment's (D9).
          jsonb_build_object('code','approve_with_count','name','Approve with its count','from','draft','to','approved','required_permission','inventory.adjust','is_automatic',true,'sort_order',18),
          -- The door's: erp.post_adjustment_lines() writes the stock and then
          -- takes it, derived from the approval (D13) or the count's.
          jsonb_build_object('code','post','name','Post','from','approved','to','posted','required_permission','inventory.adjust','is_automatic',true,'sort_order',20),
          jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','inventory.adjust','sort_order',510),
          jsonb_build_object('code','cancel_approved','name','Cancel','from','approved','to','cancelled','required_permission','inventory.adjust','sort_order',520)))),
    jsonb_build_object('kind', 'approval_chain', 'key', 'stock_adjustment_value', 'payload',
      jsonb_build_object(
        'code', 'stock_adjustment_value', 'name', 'Stock adjustment value approval',
        'object_type', 'document',
        'applies_when', jsonb_build_object('==', jsonb_build_array(jsonb_build_object('var', 'document_type'), 'stock_adjustment')),
        'priority', 100,
        'value_field', 'value_at_cost_minor',
        'material_fields', jsonb_build_array('line_fingerprint'),
        'steps', jsonb_build_array(
          -- Off until the organisation sets a threshold (D10): the condition
          -- is then {">": [{"var": "value_at_cost_minor"}, <minor units>]}.
          jsonb_build_object('seq', 1, 'code', 'stock_controller', 'name', 'Stock controller',
                             'approver_kind', 'role', 'role', 'inventory', 'min_approvals', 1,
                             'condition', false)))),
    jsonb_build_object('kind', 'numbering_rule', 'key', 'stock_adjustment', 'payload',
      jsonb_build_object('code','stock_adjustment','prefix','ADJ-','pad_to',6,
                         'reset_period','yearly','next_value',1)),
    jsonb_build_object('kind', 'document_type', 'key', 'stock_adjustment', 'payload',
      jsonb_build_object('code','stock_adjustment','base_type','adjustment',
                         'name','Stock adjustment','numbering_rule','stock_adjustment',
                         'state_machine','stock_adjustment',
                         'approval_chain','stock_adjustment_value',
                         'stock_movement_type','count_adjustment',
                         'create_permission','inventory.adjust')))
$$;

comment on function erp.stock_adjustment_pack_items() is
  'The stock adjustment as inventory-operations version 9 installs it (20260928500000): version 2 of its '
  'lifecycle, the value chain whose threshold is off until set, its numbering rule and its document type, '
  'the items erp.configure_inventory() and the upgrade register both read.';

create or replace function erp.count_task_lifecycle_item()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- The count task's lifecycle, version 2 (20260928500000), read by
  -- erp.configure_inventory() for a new install and by the upgrade register
  -- for an organisation on version 8 or earlier, so the two cannot disagree.
  -- The states are erp.count_task_status. Each move carries the permission
  -- its door asks for: recording inventory.count (a scanner confirmation is
  -- the system's, erp.derived_move_fact()); posting, recounting and
  -- discarding a figure inventory.adjust; withdrawing a task nobody has
  -- counted inventory.count, as raising it does. Approve and reject are the
  -- approval request's outcome, made by erp.settle_approval_outcome() on the
  -- approver's decision. cancel_approved puts back a count whose post was
  -- refused, or that is held because its status is not known
  -- (20260928500000, D14), through erp.cancel_count_task(). No screen draws
  -- them: each is made by the door that does the work
  -- (erp.move_count_task()).
  select jsonb_build_object('kind','state_machine','key','count_task_lifecycle','payload',
        jsonb_build_object(
          'code','count_task_lifecycle','object_type','count_task','name','Count task',
          'states', jsonb_build_array(
            jsonb_build_object('code','open','name','Open','is_initial',true,'sort_order',10),
            jsonb_build_object('code','counted','name','Counted','sort_order',20),
            jsonb_build_object('code','pending_approval','name','Waiting for approval','sort_order',30),
            jsonb_build_object('code','approved','name','Approved','is_committed',true,'sort_order',40),
            jsonb_build_object('code','rejected','name','Refused','sort_order',50),
            jsonb_build_object('code','posted','name','Posted','is_terminal',true,'is_committed',true,'sort_order',60),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','record_approved','name','Record','from','open','to','approved','required_permission','inventory.count','sort_order',10),
            jsonb_build_object('code','record_pending','name','Record','from','open','to','pending_approval','required_permission','inventory.count','sort_order',11),
            jsonb_build_object('code','record_counted','name','Record','from','open','to','counted','required_permission','inventory.count','sort_order',12),
            jsonb_build_object('code','approve','name','Approve','from','pending_approval','to','approved','required_permission','inventory.adjust','sort_order',20),
            jsonb_build_object('code','reject','name','Refuse','from','pending_approval','to','rejected','required_permission','inventory.adjust','sort_order',21),
            jsonb_build_object('code','post','name','Post','from','approved','to','posted','required_permission','inventory.adjust','sort_order',30),
            jsonb_build_object('code','recount','name','Count again','from','rejected','to','open','required_permission','inventory.adjust','sort_order',40),
            jsonb_build_object('code','recount_counted','name','Count again','from','counted','to','open','required_permission','inventory.adjust','sort_order',41),
            jsonb_build_object('code','cancel','name','Cancel','from','open','to','cancelled','required_permission','inventory.count','sort_order',90),
            jsonb_build_object('code','cancel_counted','name','Cancel','from','counted','to','cancelled','required_permission','inventory.adjust','sort_order',91),
            jsonb_build_object('code','cancel_rejected','name','Cancel','from','rejected','to','cancelled','required_permission','inventory.adjust','sort_order',92),
            jsonb_build_object('code','cancel_approved','name','Cancel','from','approved','to','cancelled','required_permission','inventory.adjust','sort_order',93))))
$$;

comment on function erp.count_task_lifecycle_item() is
  'The count task''s lifecycle as inventory-operations version 9 installs it (20260928500000): version 1''s '
  'moves and cancel_approved, for a count whose post was refused or whose status is not known.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. The upgrade register: version 9 for an organisation on version 8
-- ─────────────────────────────────────────────────────────────────────────────

update erp_ref.module_installer
   set current_version = 9,
       description = description
         || ' Version 9 (20260928500000): a stock adjustment is approved and posted as it is raised '
         || 'unless its value at cost is over the organisation''s threshold, a count''s adjustment is '
         || 'approved with its count, and a count whose post was refused can be cancelled.'
 where install_code = 'inventory-operations' and current_version = 8;

-- The lifecycle, the chain and the type, and the count task's lifecycle.
-- The numbering rule is unchanged.
insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
select 'inventory-operations', 9, i.value ->> 'kind', i.value ->> 'key', i.value -> 'payload',
       300 + 10 * i.ordinality::integer
  from jsonb_array_elements(erp.stock_adjustment_pack_items()
                            || jsonb_build_array(erp.count_task_lifecycle_item())) with ordinality as i(value, ordinality)
 where i.value ->> 'kind' <> 'numbering_rule'
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

do $register$
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'inventory-operations') is distinct from 9 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the inventory-operations installer is not at version 9';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       join jsonb_array_elements(erp.stock_adjustment_pack_items()
                                 || jsonb_build_array(erp.count_task_lifecycle_item())) i
         on i.value ->> 'kind' = ui.object_kind and i.value ->> 'key' = ui.object_key
        and i.value -> 'payload' = ui.payload
      where ui.install_code = 'inventory-operations' and ui.to_version = 9) <> 4
     or (select count(*) from erp_ref.module_upgrade_item ui
          where ui.install_code = 'inventory-operations' and ui.to_version = 9) <> 4 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 9 of inventory-operations is not the stock adjustment''s lifecycle, chain and type and the count task''s lifecycle';
  end if;
end
$register$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. A reason that requires approval is worth more than any threshold
-- ─────────────────────────────────────────────────────────────────────────────

do $context$
declare
  v_sig constant text := 'erp.document_transition_context(uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    v_ctx := v_ctx || jsonb_build_object('value_at_cost_minor', erp.document_value_at_cost_minor(p_document_id));
  end if;
$o$;
  v_new constant text := $n$    v_ctx := v_ctx || jsonb_build_object('value_at_cost_minor', erp.document_value_at_cost_minor(p_document_id));
  end if;
  -- A stock adjustment whose reason the register says requires approval is
  -- worth more than any threshold clears (20260928500000), as stock with no
  -- cost is: with no threshold set nobody is asked, and once one is set it
  -- always asks (D10).
  if dt.base_type_code = 'adjustment' and erp.adjustment_reason_requires_approval(p_document_id) then
    v_ctx := v_ctx || jsonb_build_object('value_at_cost_minor', 9223372036854775807::bigint,
                                         'reason_requires_approval', true);
  end if;
$n$;
  v_hits integer;
begin
  if position('erp.adjustment_reason_requires_approval(' in v_def) > 0 then
    raise notice '% already reads the reason; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % value at cost anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$context$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The facts, read again with the adjustment's state locked
-- ─────────────────────────────────────────────────────────────────────────────

do $derived$
declare
  v_sig constant text := 'erp.derived_move_fact(text,uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$           when dt.base_type_code = 'adjustment' and p_transition_code in ('approve', 'post')
            and erp.object_current_state('document', p_object_id)
                  = case p_transition_code when 'approve' then 'draft' else 'approved' end
            and erp.count_task_is_approved(p_object_id)
             then 'erp.count_task_is_approved'
$o$;
  b0 constant text := $n$           -- Version 2 names the count's approve approve_with_count
           -- (20260928500000); version 1's approve from draft stays for a
           -- count's adjustment raised on it.
           when dt.base_type_code = 'adjustment' and p_transition_code in ('approve', 'approve_with_count', 'post')
            and erp.object_current_state('document', p_object_id)
                  = case p_transition_code when 'post' then 'approved' else 'draft' end
            and erp.count_task_is_approved(p_object_id)
             then 'erp.count_task_is_approved'
           -- A write-off's submit, the door's (20260928500000): the person
           -- was asked inventory.write_off by erp.write_off_stock(), which
           -- raised the adjustment and asks for this.
           when dt.base_type_code = 'adjustment' and p_transition_code = 'submit'
            and erp.object_current_state('document', p_object_id) = 'draft'
            and d.attributes ->> 'written_off' = 'true'
             then 'erp.write_off_stock'
           -- A stock adjustment approved within its threshold, when the
           -- approval its submit asked for asked nobody (20260928500000),
           -- asked for by erp.approve_adjustment_within_threshold().
           when dt.base_type_code = 'adjustment' and p_transition_code = 'approve_within_threshold'
            and erp.object_current_state('document', p_object_id) = 'pending_approval'
            and erp.approval_asked_nobody(p_object_id)
             then 'erp.approval_asked_nobody'
           -- And posted as it is approved (20260928500000, D13), asked for by
           -- erp.post_adjustment_on_approval() through its door.
           when dt.base_type_code = 'adjustment' and p_transition_code = 'post'
            and erp.adjustment_is_approved(p_object_id)
             then 'erp.adjustment_is_approved'
$n$;
  a1 constant text := $o$           when dt.base_type_code = 'transfer_order' and p_transition_code in ('approve', 'reject')
$o$;
  b1 constant text := $n$           -- And a stock adjustment the same way (20260928500000).
           when dt.base_type_code in ('transfer_order', 'adjustment') and p_transition_code in ('approve', 'reject')
$n$;
  n integer;
begin
  if position('erp.adjustment_is_approved' in v_def) > 0 then
    raise notice '% already names the stock adjustment''s facts; left as it is', v_sig;
    return;
  end if;
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a0, ''))) / length(a0),
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % adjustment arm found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(v_def, a0, b0), a1, b1);
end
$derived$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B2. The two routines that make the derived moves
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.approve_adjustment_within_threshold(p_document_id uuid)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_prev text;
  v_to   text;
begin
  -- A stock adjustment just submitted whose approval asked nobody is
  -- approved (20260928500000), and so posted. Called by
  -- erp.transition_document() after every submit of a stock adjustment;
  -- returns the state reached, or null and does nothing to one whose version
  -- declares no such move from where it stands, or whose approval asked
  -- somebody. The move is the system's, derived from
  -- erp.approval_asked_nobody(), named in erp.deriving_move immediately
  -- before it and put back after.
  if p_document_id is null
     or not erp.document_declares_move(p_document_id, 'approve_within_threshold')
     or not erp.approval_asked_nobody(p_document_id) then
    return null;
  end if;

  v_prev := coalesce(current_setting('erp.deriving_move', true), '');
  perform set_config('erp.deriving_move', p_document_id::text || ':approve_within_threshold', true);
  v_to := erp.transition_document(p_document_id, 'approve_within_threshold',
                                  'Nobody was asked to approve it');
  perform set_config('erp.deriving_move', v_prev, true);
  return v_to;
end;
$$;

revoke all on function erp.approve_adjustment_within_threshold(uuid) from public, anon;

comment on function erp.approve_adjustment_within_threshold(uuid) is
  'Approves a stock adjustment just submitted whose approval asked nobody (20260928500000): the '
  'system''s move, derived from erp.approval_asked_nobody(). The approval then posts it.';

create or replace function erp.post_adjustment_on_approval(p_document_id uuid)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_site   uuid;
  v_prev   text;
begin
  -- A version 2 stock adjustment is posted as it is approved (20260928500000,
  -- D13): within its threshold as it is raised, or by the approver's approve.
  -- Called by erp.transition_document() after an approve; returns the state
  -- reached, or null and does nothing to a version 1 adjustment, which
  -- Confirm posts as it always did, or to one that has already moved stock.
  -- The post is the door's: erp.post_adjustment_lines() writes the legs and
  -- the journals and takes the move, derived from erp.adjustment_is_approved()
  -- and named immediately before it. What the person was asked for, the raise
  -- asked: inventory.adjust, and finance.post for a date before today.
  if not erp.adjustment_is_approved(p_document_id)
     or exists (select 1 from erp.stock_movement m
                 where m.tenant_id = v_tenant and m.document_id = p_document_id) then
    return null;
  end if;

  select d.site_id into v_site from erp.document d
   where d.tenant_id = v_tenant and d.id = p_document_id;

  v_prev := coalesce(current_setting('erp.deriving_move', true), '');
  perform set_config('erp.deriving_move', p_document_id::text || ':post', true);
  perform erp.post_adjustment_lines(p_document_id, clock_timestamp(), erp.local_today(v_site));
  perform set_config('erp.deriving_move', v_prev, true);
  return erp.document_state_code(p_document_id);
end;
$$;

revoke all on function erp.post_adjustment_on_approval(uuid) from public, anon;

comment on function erp.post_adjustment_on_approval(uuid) is
  'Posts a version 2 stock adjustment as it is approved (20260928500000, D13), through '
  'erp.post_adjustment_lines(), derived from erp.adjustment_is_approved().';

-- ─────────────────────────────────────────────────────────────────────────────
-- B3. erp.transition_document() asks them
--
-- Before M1's stock guard: approve_within_threshold only when nobody was
-- asked, and approve_with_count only on the count's fact. At the end: a submit
-- that asked nobody is approved, and an approval posts. Applied once: a body
-- that already asks them is left alone.
-- ─────────────────────────────────────────────────────────────────────────────

do $transition_document$
declare
  v_sig constant text := 'erp.transition_document(uuid, text, text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  -- A transfer order or stock adjustment moves because its stock did
  -- (20260928000000): by what the state a move reaches means, not its code,
$o$;
  v_new constant text := $n$  -- A transfer order or stock adjustment waiting for approval is rejected
  -- by the people its approval asked, or withdrawn by the person who asked
  -- (20260928500000): not by anybody else who may move stock. A rejection
  -- decided under My approvals is the request's, derived and named.
  if dt.base_type_code in ('transfer_order', 'adjustment') and p_transition_code = 'reject'
     and coalesce(current_setting('erp.deriving_move', true), '') <> p_document_id::text || ':reject'
     and erp.reject_refusal(p_document_id) is not null then
    raise exception
      'CLOVEERP_REJECT_IS_THE_APPROVERS: % waits for the people its approval asked, and they reject it',
      coalesce(d.document_number, p_document_id::text)
      using errcode = '42501',
            hint = 'Leave it to the people named under My approvals, or ask the person who raised it to withdraw it.';
  end if;

  -- A stock adjustment is approved within its threshold only when its
  -- approval asked nobody, and with a count only when it is that count's
  -- variance (20260928500000). Each is the system's move; pressed by a
  -- person, it is refused by name.
  if dt.base_type_code = 'adjustment' then
    if p_transition_code = 'approve_within_threshold'
       and erp.document_declares_move(p_document_id, 'approve_within_threshold')
       and not erp.approval_asked_nobody(p_document_id) then
      raise exception
        'CLOVEERP_ADJUSTMENT_AWAITS_APPROVAL: % is waiting for the approval its value asked for',
        coalesce(d.document_number, p_document_id::text)
        using errcode = '23514',
              hint = 'The people asked decide it under My approvals, and the adjustment is posted or sent back to draft as they decide.';
    end if;
    if p_transition_code = 'approve_with_count'
       and erp.document_declares_move(p_document_id, 'approve_with_count')
       and erp.derived_move_fact('document', p_document_id, 'approve_with_count') is null then
      raise exception
        'CLOVEERP_ADJUSTMENT_APPROVED_WITH_ITS_COUNT: % is not the variance of an approved count, so it is approved for what it is worth',
        coalesce(d.document_number, p_document_id::text)
        using errcode = '23514',
              hint = 'Submit it for approval. Below the organisation''s threshold it is approved and posted as it is submitted.';
    end if;
  end if;

  -- A transfer order or stock adjustment moves because its stock did
  -- (20260928000000): by what the state a move reaches means, not its code,
$n$;
  v_old_end constant text := $o$  elsif dt.base_type_code = 'transfer_order' and v_to = 'received' then
    v_to := coalesce(erp.close_transfer_when_received(p_document_id, 'Received in full'), v_to);
  end if;
$o$;
  v_new_end constant text := $n$  elsif dt.base_type_code = 'transfer_order' and v_to = 'received' then
    v_to := coalesce(erp.close_transfer_when_received(p_document_id, 'Received in full'), v_to);
  -- A stock adjustment the same way (20260928500000): submitted with nobody
  -- asked to approve it, it is approved within its threshold; approved, on
  -- version 2, it is posted (D13). A count's adjustment is posted by its
  -- count, and a version 1 one by Confirm.
  elsif dt.base_type_code = 'adjustment' and p_transition_code = 'submit' then
    v_to := coalesce(erp.approve_adjustment_within_threshold(p_document_id), v_to);
  elsif dt.base_type_code = 'adjustment' and v_to = 'approved'
        and p_transition_code in ('approve', 'approve_within_threshold') then
    v_to := coalesce(erp.post_adjustment_on_approval(p_document_id), v_to);
  end if;
$n$;
  n integer;
begin
  if position('erp.post_adjustment_on_approval(' in v_def) > 0
     and position('erp.reject_refusal(' in v_def) > 0 then
    raise notice '% already posts an approved adjustment; left as it is', v_sig;
    return;
  end if;
  if position('erp.close_transfer_when_received(' in v_def) = 0 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % no longer closes a received transfer (20260928200000)', v_sig;
  end if;
  foreach n in array array[
      (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old),
      (length(v_def) - length(replace(v_def, v_old_end, ''))) / length(v_old_end)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % an anchor was found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(v_def, v_old, v_new), v_old_end, v_new_end);
end
$transition_document$;

-- The screens draw Reject only for those who may make it (20260928500000).
do $refusal$
declare
  v_sig constant text := 'erp.transition_refusal(uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  if p_transition_code is distinct from 'approve' or v_tenant is null then
    return null;
  end if;
$o$;
  v_new constant text := $n$  -- Reject, of a transfer order or stock adjustment waiting for approval,
  -- is the approvers' and the asker's (20260928500000).
  if p_transition_code = 'reject' then
    return erp.reject_refusal(p_document_id);
  end if;

  if p_transition_code is distinct from 'approve' or v_tenant is null then
    return null;
  end if;
$n$;
  n integer;
begin
  if position('erp.reject_refusal(' in v_def) > 0 then
    raise notice '% already reads the rejection; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % approve anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$refusal$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B4. Raising refuses a count's reason, and submits
-- ─────────────────────────────────────────────────────────────────────────────

do $raise$
declare
  v_sig constant text := 'erp.raise_stock_adjustment(uuid,text,jsonb,date,text,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$  perform erp.check_reason_code('STOCK_ADJUSTMENT', p_reason_code, p_note);
$o$;
  b0 constant text := $n$  -- A count variance is what a count found (20260928500000, D11): only the
  -- count's own door, erp.raise_count_adjustment(), writes one.
  if upper(btrim(p_reason_code)) = 'COUNT_VARIANCE' then
    raise exception
      'CLOVEERP_COUNT_VARIANCE_IS_A_COUNTS: a count variance is written by the count that found it, not raised by hand'
      using errcode = '23514',
            hint = 'Count the place from the Counting worklist, and its variance is posted as its own adjustment. If the stock changed for another reason, pick that reason.';
  end if;

  perform erp.check_reason_code('STOCK_ADJUSTMENT', p_reason_code, p_note);
$n$;
  a1 constant text := $o$  select * into d from erp.document where tenant_id = v_tenant and id = v_id;
$o$;
  b1 constant text := $n$  -- Submitted as it is raised, where its lifecycle declares a submit
  -- (20260928500000): approved and posted at once when nobody need approve
  -- it, and waiting for the people its value asked for otherwise. A draft
  -- with no lines is left to be filled and submitted.
  if v_added > 0 and erp.document_declares_move(v_id, 'submit') then
    perform erp.transition_document(v_id, 'submit', 'Raised');
  end if;

  select * into d from erp.document where tenant_id = v_tenant and id = v_id;
$n$;
  n integer;
begin
  if position('CLOVEERP_COUNT_VARIANCE_IS_A_COUNTS' in v_def) > 0 then
    raise notice '% already refuses a count''s reason and submits; left as it is', v_sig;
    return;
  end if;
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a0, ''))) / length(a0),
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % raise anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(v_def, a0, b0), a1, b1);
end
$raise$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B5. A count's adjustment is approved with its count (D9)
-- ─────────────────────────────────────────────────────────────────────────────

do $count_adjustment$
declare
  v_sig constant text := 'erp.raise_count_adjustment(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  perform set_config('erp.deriving_move', v_doc::text || ':approve', true);
  perform erp.transition_document(v_doc, 'approve', 'Approved with its count');
$o$;
  v_new constant text := $n$  -- By approve_with_count where the version declares it (20260928500000),
  -- and by version 1's approve from draft where it does not.
  perform set_config('erp.deriving_move', v_doc::text || ':' ||
    case when erp.document_declares_move(v_doc, 'approve_with_count') then 'approve_with_count' else 'approve' end,
    true);
  perform erp.transition_document(v_doc,
    case when erp.document_declares_move(v_doc, 'approve_with_count') then 'approve_with_count' else 'approve' end,
    'Approved with its count');
$n$;
  n integer;
begin
  if position('approve_with_count' in v_def) > 0 then
    raise notice '% already approves with the count; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % approve anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$count_adjustment$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B6. Decided under My approvals, the adjustment moves with the decision
-- ─────────────────────────────────────────────────────────────────────────────

do $settle$
declare
  v_sig constant text := 'erp.settle_approval_outcome(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$                    and dt.base_type_code = 'transfer_order')
$o$;
  v_new constant text := $n$                    -- And a stock adjustment (20260928500000), which the
                    -- approval then posts.
                    and dt.base_type_code in ('transfer_order', 'adjustment'))
$n$;
  n integer;
begin
  if position('which the' || E'\n' || '                    -- approval then posts' in v_def) > 0 then
    raise notice '% already moves a stock adjustment; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % transfer anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$settle$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B7. A submitted adjustment is not amended and takes no new line (D6)
-- ─────────────────────────────────────────────────────────────────────────────

do $amend$
declare
  v_sig constant text := 'erp.amendment_allowed(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  elsif erp.transfer_is_past_draft(p_document_id) then
$o$;
  v_new constant text := $n$  -- A stock adjustment the same (20260928500000): what was approved is
  -- what is written off.
  elsif erp.adjustment_is_past_draft(p_document_id) then
    allowed := false;
    cut_off := 'adjustment_submitted';
    detail := format('the stock adjustment is %s, and is changed only as a draft: have one waiting ' ||
                     'for approval rejected back to draft, or raise a second adjustment',
                     coalesce(v_state, 'past its draft'));
  elsif erp.transfer_is_past_draft(p_document_id) then
$n$;
  n integer;
begin
  if position('adjustment_submitted' in v_def) > 0 then
    raise notice '% already refuses a submitted adjustment; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % transfer cut-off anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$amend$;

do $add_line$
declare
  v_sig constant text := 'erp.add_document_line(uuid,uuid,numeric,bigint,text,date)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  if erp.transfer_is_past_draft(p_document_id) then
$o$;
  v_new constant text := $n$  -- A stock adjustment the same (20260928500000).
  if erp.adjustment_is_past_draft(p_document_id) then
    raise exception
      'CLOVEERP_ADJUSTMENT_CHANGED_ONLY_AS_A_DRAFT: % has been submitted, so it takes no new line',
      d.document_number
      using errcode = '23514',
            hint = 'Have it rejected back to draft and change it there, or raise a second adjustment for the rest.';
  end if;

  if erp.transfer_is_past_draft(p_document_id) then
$n$;
  n integer;
begin
  if position('erp.adjustment_is_past_draft(' in v_def) > 0 then
    raise notice '% already refuses a submitted adjustment; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % transfer anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$add_line$;

do $identity$
declare
  v_sig constant text := 'erp.set_line_stock_identity(uuid,uuid,uuid,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  if erp.transfer_is_past_draft(d.id) then
$o$;
  v_new constant text := $n$  -- A submitted stock adjustment the same (20260928500000).
  if erp.adjustment_is_past_draft(d.id) then
    raise exception
      'CLOVEERP_ADJUSTMENT_CHANGED_ONLY_AS_A_DRAFT: % has been submitted, so no stock is pinned to its lines now',
      d.document_number
      using errcode = '23514',
            hint = 'Have it rejected back to draft and change it there, or raise a second adjustment for the rest.';
  end if;

  if erp.transfer_is_past_draft(d.id) then
$n$;
  n integer;
begin
  if position('erp.adjustment_is_past_draft(' in v_def) > 0 then
    raise notice '% already refuses a submitted adjustment; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % transfer anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$identity$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B8. A write-off is a stock adjustment (D12)
--
-- The same signature, the same permission asked first, and a scrap movement
-- at what the stock cost with the person's words on it, as before. What
-- changes is that it goes through a stock adjustment under EXPIRY_WRITE_OFF,
-- so the organisation's threshold, once set, applies to it: over it, the
-- write-off waits for somebody else and returns no movement.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.write_off_stock(p_item_id uuid, p_site_id uuid, p_location_id uuid,
                                               p_quantity numeric, p_reason text,
                                               p_batch_id uuid default null,
                                               p_owner_party_id uuid default null)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  s         erp.site%rowtype;
  v_company uuid;
  v_owner   uuid;
  v_cost    bigint;
  v_uom     uuid;
  v_id      bigint;
  v_doc     uuid;
  v_on      date;
  v_prev    text;
begin
  if coalesce(p_reason, '') = '' then
    raise exception
      'CLOVEERP_WRITE_OFF_NEEDS_REASON: stock is not written off without one'
      using errcode = '23514',
            hint = 'Say why the stock is lost; the reason is kept on the movement.';
  end if;

  perform erp.authorise('inventory.write_off', null, p_site_id, null,
                        'item', p_item_id);

  -- Stock found is not a loss (20260928500000): a line of less than nothing
  -- would put stock on the shelf under the name of a write-off.
  if coalesce(p_quantity, 0) <= 0 then
    raise exception
      'CLOVEERP_WRITE_OFF_NEEDS_A_QUANTITY: % is not a quantity of stock lost', coalesce(p_quantity::text, 'nothing')
      using errcode = '23514',
            hint = 'Say how many are lost as a positive number. Stock found is raised as a stock adjustment with a positive line.';
  end if;

  select i.stock_uom_id into v_uom from erp.item i
   where i.tenant_id = v_tenant and i.id = p_item_id;

  v_company := erp.entity_party_for_site(p_site_id);
  v_owner   := coalesce(p_owner_party_id, v_company);

  -- An organisation with no stock adjustment type, or one still on version
  -- 1 of its lifecycle, which declares no submit, writes off as it always
  -- did: a scrap movement, with no document.
  if not exists (select 1 from erp.document_type dt
                   join erp.state_machine m
                     on m.tenant_id = dt.tenant_id and m.code = dt.state_machine_code
                    and m.object_type = 'document' and m.status = 'active'
                   join erp.state_machine_version v
                     on v.tenant_id = m.tenant_id and v.state_machine_id = m.id and v.status = 'active'
                   join erp.transition t
                     on t.tenant_id = v.tenant_id and t.state_machine_version_id = v.id and t.code = 'submit'
                  where dt.tenant_id = v_tenant and dt.code = 'stock_adjustment'
                    and dt.base_type_code = 'adjustment' and dt.status = 'active') then
    -- Consuming cost layers, so a write-off relieves inventory at what the
    -- stock cost rather than at nothing — and only when the stock is the
    -- company's: a supplier's consigned position carries no cost on these
    -- books.
    v_cost := case when v_owner = v_company
                   then erp.issue_cost(p_item_id, p_site_id, p_quantity) end;

    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
      from_location_id, from_status, quantity, uom_id, unit_cost_minor, currency,
      reason_code, owner_party_id)
    select v_tenant, s2.entity_id, p_site_id, 'scrap', p_item_id, p_batch_id,
           p_location_id, 'available', p_quantity, v_uom, v_cost,
           coalesce((select e.base_currency from erp.entity e
                      where e.tenant_id = v_tenant limit 1), 'GBP'),
           left(p_reason, 64), v_owner
      from erp.site s2 where s2.tenant_id = v_tenant and s2.id = p_site_id
    returning id into v_id;

    perform erp.post_movement_finance(v_id);

    return v_id;
  end if;

  select * into s from erp.site where tenant_id = v_tenant and id = p_site_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_SITE: %', p_site_id using errcode = '23503',
      hint = 'The site does not exist in this organisation.';
  end if;

  -- The register's code for stock written off, and whatever the organisation
  -- insists on for it; the person's words are its note.
  perform erp.check_reason_code('STOCK_ADJUSTMENT', 'EXPIRY_WRITE_OFF', p_reason);

  -- Opened the way the count's own adjustment is: the permission this door
  -- asks is inventory.write_off, which the person has been asked above.
  v_doc := erp.create_document('stock_adjustment', s.entity_id, p_site_id, null,
                               null, null, null);
  v_on := erp.local_today(p_site_id);

  update erp.document
     set document_date = v_on,
         posting_date  = v_on,
         stock_owner_party_id = v_owner,
         attributes = coalesce(attributes, '{}'::jsonb)
                      || jsonb_build_object('reason_code', 'EXPIRY_WRITE_OFF',
                                            'reason_note', btrim(p_reason),
                                            'written_off', true),
         updated_at = now()
   where tenant_id = v_tenant and id = v_doc;

  insert into erp.document_line (
    tenant_id, document_id, line_no, item_id, description, quantity, uom_id,
    batch_id, location_id, unit_price_minor, net_minor)
  values (
    v_tenant, v_doc, 10, p_item_id, erp.line_description(p_item_id, null),
    -p_quantity, v_uom, p_batch_id, p_location_id, 0, 0);

  -- Submitted as the door's move, derived from the write-off; approved and
  -- posted within the threshold, or left waiting for the people it asked.
  v_prev := coalesce(current_setting('erp.deriving_move', true), '');
  perform set_config('erp.deriving_move', v_doc::text || ':submit', true);
  perform erp.transition_document(v_doc, 'submit', 'Written off');
  perform set_config('erp.deriving_move', v_prev, true);

  -- The movement, once there is one: none while it waits for approval.
  select m.id into v_id
    from erp.stock_movement m
   where m.tenant_id = v_tenant and m.document_id = v_doc
   order by m.id
   limit 1;

  return v_id;
end;
$$;

revoke all on function erp.write_off_stock(uuid, uuid, uuid, numeric, text, uuid, uuid) from public, anon;

comment on function erp.write_off_stock(uuid, uuid, uuid, numeric, text, uuid, uuid) is
  'Writes stock off under inventory.write_off, which is its own permission because a write-off is a loss '
  'rather than an adjustment; the owner may be named so a consigned position is written off as the '
  'supplier''s. Since 20260928500000 through a stock adjustment under EXPIRY_WRITE_OFF, so the '
  'organisation''s threshold applies: the movement it returns is null while the write-off waits for '
  'approval.';

-- The line routine writes a write-off's leg as a scrap with the person's
-- words, as the write-off always did.
do $lines$
declare
  v_sig constant text := 'erp.post_adjustment_lines(uuid,timestamp with time zone,date)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  v_type := coalesce(dt.stock_movement_type, 'count_adjustment');
$o$;
  v_new constant text := $n$  v_type := coalesce(dt.stock_movement_type, 'count_adjustment');
  -- A write-off raised by erp.write_off_stock() (20260928500000) is still a
  -- scrap at what the stock cost, with the person's words on the movement,
  -- so the ledger reads as it did before it had a document.
  if d.attributes ->> 'written_off' = 'true' then
    v_type := 'scrap';
    v_reason := coalesce(left(nullif(btrim(d.attributes ->> 'reason_note'), ''), 64), v_reason);
  end if;
$n$;
  n integer;
begin
  if position('written_off' in v_def) > 0 then
    raise notice '% already writes a write-off as a scrap; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % movement type anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$lines$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B9. A count whose post was refused is put back (M5, D14)
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.cancel_count_task(p_task_id uuid, p_reason text)
returns erp.count_task_status
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  t        erp.count_task%rowtype;
begin
  select * into t from erp.count_task
   where tenant_id = v_tenant and id = p_task_id for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_COUNT_TASK: %', p_task_id using errcode = '23503',
      hint = 'The count task does not exist in this organisation.';
  end if;

  -- Withdrawing a task nobody has counted is raising's other half, and asks
  -- what raising asks. Discarding a figure somebody recorded, or an approved
  -- one whose post was refused, asks what sending it back to be counted
  -- again asks.
  perform erp.authorise(
    case when t.status in ('counted', 'rejected', 'approved') then 'inventory.adjust' else 'inventory.count' end,
    null, t.site_id, null, 'count_task', p_task_id);

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'CLOVEERP_COUNT_CANCELLATION_NEEDS_A_REASON: say why count % is being cancelled', p_task_id
      using errcode = '22023', hint = 'Say why the count is being cancelled.';
  end if;

  -- Approved, and put back (20260928500000, D14): only one whose post was
  -- refused, or that is held because nobody knows which stock it counts,
  -- and only while nothing has been posted for it. Any other approved count
  -- is posted.
  if t.status = 'approved' then
    if t.adjustment_document_id is not null or t.posted_at is not null then
      raise exception 'CLOVEERP_COUNT_TASK_NOT_CANCELLABLE: count % has been posted through its adjustment, so it is not cancelled',
        p_task_id
        using errcode = '23514',
              hint = 'If the stock is still wrong, count the place again.';
    end if;
    if coalesce(t.post_held_reason, '') not like 'post_refused:%'
       and coalesce(t.post_held_reason, '') not like 'status_unknown:%' then
      raise exception 'CLOVEERP_COUNT_TASK_NOT_CANCELLABLE: count % is approved and its post has not been refused, so it is posted rather than cancelled',
        p_task_id
        using errcode = '23514',
              hint = 'Post it from the Counting worklist. Only an approved count whose post was refused, or whose stock status is not known, is cancelled.';
    end if;
    if exists (select 1 from erp.object_state os
                where os.tenant_id = v_tenant and os.object_type = 'count_task' and os.object_id = p_task_id)
       and not exists (select 1 from erp.object_state os
                         join erp.transition tr
                           on tr.tenant_id = os.tenant_id
                          and tr.state_machine_version_id = os.state_machine_version_id
                          and tr.from_state_id = os.current_state_id
                        where os.tenant_id = v_tenant and os.object_type = 'count_task'
                          and os.object_id = p_task_id and tr.code = 'cancel_approved') then
      raise exception 'CLOVEERP_COUNT_TASK_NOT_CANCELLABLE: count % was raised on a count lifecycle with no way out of approved',
        p_task_id
        using errcode = '23514',
              hint = 'Take inventory-operations version 9 on the Configuration screen for counts raised after it. This one stays approved; post it once its place is put right.';
    end if;
  elsif t.status not in ('open', 'counted', 'rejected') then
    -- Open, counted or refused: nobody is deciding it and nothing has posted.
    raise exception 'CLOVEERP_COUNT_TASK_NOT_CANCELLABLE: count % is %, and only one open, counted or refused is cancelled',
      p_task_id, t.status
      using errcode = '23514',
            hint = 'Decide a waiting count first: refused, it can be counted again or cancelled. Post an approved one.';
  end if;

  -- The lock goes with it, as posting and refusing release it: a lock left
  -- open would go on gathering movement into a task nobody is counting, and
  -- the next count of the place would inherit it.
  update erp.count_lock l
     set released_at = now(), updated_at = now()
   where l.tenant_id = v_tenant and l.count_task_id = p_task_id
     and l.released_at is null;

  perform erp.move_count_task(p_task_id,
    case t.status when 'open' then 'cancel'
                  when 'counted' then 'cancel_counted'
                  when 'approved' then 'cancel_approved'
                  else 'cancel_rejected' end,
    'cancelled', btrim(p_reason));

  return 'cancelled'::erp.count_task_status;
end;
$$;

revoke all on function erp.cancel_count_task(uuid, text) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- B10. The demonstration's Saturday write-down is a damaged unit
--
-- A past Saturday cannot be counted today, and a COUNT_VARIANCE typed by hand
-- is refused (D11). Raised, and so posted within its threshold, which the
-- demonstration never sets; on version 1 by the clicks it always took.
-- ─────────────────────────────────────────────────────────────────────────────

do $seeder$
declare
  v_sig constant text := 'erp.seed_demo_history(date,date,numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$                    v_site, 'COUNT_VARIANCE',
$o$;
  b0 constant text := $n$                    v_site, 'DAMAGE_STORAGE',
$n$;
  a1 constant text := $o$                    v_day, 'One short on the weekend count',
$o$;
  b1 constant text := $n$                    v_day, 'One found damaged on the weekend walk-round',
$n$;
  a2 constant text := $o$        perform erp.transition_document(v_adj, 'approve', 'demonstration');
        perform erp.post_stock_adjustment(v_adj);
$o$;
  b2 constant text := $n$        -- Posted as it was raised, on version 2 of its lifecycle
        -- (20260928500000); approved and confirmed, on version 1.
        if erp.document_declares_move(v_adj, 'approve') then
          perform erp.transition_document(v_adj, 'approve', 'demonstration');
          perform erp.post_stock_adjustment(v_adj);
        end if;
$n$;
  n integer;
begin
  if position('One found damaged on the weekend walk-round' in v_def) > 0 then
    raise notice '% already writes a damaged unit down; left as it is', v_sig;
    return;
  end if;
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a0, ''))) / length(a0),
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1),
      (length(v_def) - length(replace(v_def, a2, ''))) / length(a2)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % weekend anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(replace(v_def, a0, b0), a1, b1), a2, b2);
end
$seeder$;

do $catch_up$
declare
  v_sig constant text := 'erp.demonstration_catch_up()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$'Inventory operations was not upgraded, so its counts and transfers move as they did: %s'$o$;
  v_new constant text := $n$'Inventory operations was not upgraded, so its counts, transfers and stock adjustments move as they did: %s'$n$;
  n integer;
begin
  if position(v_new in v_def) > 0 then
    raise notice '% already speaks of stock adjustments; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % inventory note found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$catch_up$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B11. The undriven report reads the newest payload the installer ships
--
-- 20260922380000 excused a register row for a move the installer's CURRENT
-- version declares, before anybody has promoted it. Version 9 ships the
-- stock adjustment and not the transfer order, whose second lifecycle is
-- version 8's: the newest payload the installer ships for a lifecycle is
-- what excuses its rows, so a later version need not restate every machine
-- an earlier one shipped. A code only an older payload of the same machine
-- declared is reported as before.
-- ─────────────────────────────────────────────────────────────────────────────

do $undriven$
declare
  v_sig constant text := 'erp.undriven_transition_report(jsonb)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$          and ui.to_version = mi.current_version
$o$;
  v_new constant text := $n$          -- The newest the installer ships for this lifecycle
          -- (20260928500000).
          and ui.to_version = (select max(u2.to_version)
                                 from erp_ref.module_upgrade_item u2
                                where u2.install_code = mi.install_code
                                  and u2.object_kind = 'state_machine'
                                  and u2.object_key = r.machine_code
                                  and u2.to_version <= mi.current_version)
$n$;
  n integer;
begin
  if position('The newest the installer ships for this lifecycle' in v_def) > 0 then
    raise notice '% already reads the newest payload; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % current version anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$undriven$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C1. The register: version 2's moves of the stock adjustment
--
-- Restated whole, from 20260928200000, so the register the screens are held
-- to is read from one place.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.transition_driver_register()
returns jsonb
language sql
stable
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
      ('quotation',          'accept',                 'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('quotation',          'decline',                'screen', ''),
      ('quotation',          'expire',                 'screen', ''),

      ('sales_order',        'submit',                 'screen', ''),
      ('sales_order',        'approve',                'screen', ''),
      ('sales_order',        'reject',                 'screen', ''),
      ('sales_order',        'pick',                   'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch',               'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch_part',          'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch_part_picked',   'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch_rest',          'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'invoice',                'routine', 'erp.advance_orders_for_invoice(uuid)'),
      ('sales_order',        'close',                  'screen', ''),
      ('sales_order',        'cancel',                 'screen', ''),
      ('sales_order',        'cancel_confirmed',       'screen', ''),

      ('delivery',           'post',                   'screen', ''),
      ('delivery',           'cancel',                 'screen', ''),

      ('sales_invoice',      'issue',                  'routine', 'erp.issue_sales_invoice(uuid,uuid,uuid)'),
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
      -- Version 1 (20260917130000) and version 2 (20260928200000) of the
      -- transfer order. Documents in flight stay on version 1, so its rows
      -- stay while an organisation holds it; the moves both versions share
      -- are the despatch and receive doors', which is where the goods move.
      ('transfer_order',     'approved',               'screen', ''),
      ('transfer_order',     'issued',                 'routine', 'erp.despatch_transfer(uuid)'),
      ('transfer_order',     'in_transit',             'routine', 'erp.despatch_transfer(uuid)'),
      ('transfer_order',     'received',               'routine', 'erp.receive_transfer(uuid)'),
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
      -- Version 2: submitted as it is raised, and again by hand after a
      -- rejection; approved by somebody the chain asked, or derived from
      -- erp.approval_asked_nobody() when it asked nobody; closed derived from
      -- erp.transfer_is_received_in_full(), which a close asked for by hand
      -- also reaches, through the receiving site's routine. Neither derived
      -- move is a button.
      ('transfer_order',     'submit',                 'screen', ''),
      ('transfer_order',     'approve',                'screen', ''),
      ('transfer_order',     'reject',                 'screen', ''),
      ('transfer_order',     'approve_within_threshold', 'routine', 'erp.approve_transfer_within_threshold(uuid)'),
      ('transfer_order',     'close',                  'routine', 'erp.close_transfer_when_received(uuid,text,boolean)'),
      ('transfer_order',     'cancel',                 'screen', ''),
      ('transfer_order',     'cancel_approved',        'screen', ''),

      -- Version 1 (20260918810000) and version 2 (20260928500000) of the
      -- stock adjustment. A count's own adjustment is approved and posted by
      -- erp.post_count(), through erp.raise_count_adjustment(), both moves
      -- derived from erp.count_task_is_approved() whatever permission the
      -- organisation puts on them (20260927200000): version 1's approve from
      -- draft, version 2's approve_with_count. A hand-typed version 1
      -- adjustment is approved here and confirmed on the Stock adjustments
      -- screen; a version 2 one is submitted as it is raised, approved within
      -- its threshold derived from erp.approval_asked_nobody() or here by
      -- somebody the chain asked, and posted by the approval. The post is
      -- the line routine's on either version: the move is refused over stock
      -- nothing has written (20260928000000), so it is never a button.
      ('stock_adjustment',   'approve',                'screen', ''),
      ('stock_adjustment',   'post',                   'routine', 'erp.post_adjustment_lines(uuid,timestamp with time zone,date)'),
      ('stock_adjustment',   'cancel',                 'screen', ''),
      ('stock_adjustment',   'approved_to_cancelled',  'screen', ''),
      ('stock_adjustment',   'submit',                 'screen', ''),
      ('stock_adjustment',   'reject',                 'screen', ''),
      ('stock_adjustment',   'approve_within_threshold', 'routine', 'erp.approve_adjustment_within_threshold(uuid)'),
      ('stock_adjustment',   'approve_with_count',     'routine', 'erp.raise_count_adjustment(uuid)'),
      ('stock_adjustment',   'cancel_approved',        'screen', ''),

      -- ── The count sheet (20260927100000) ──────────────────────────────────
      -- Issued by the raise that opens it, once every place is on it; closed
      -- by the last of its counts to be posted or cancelled, derived from
      -- erp.count_sheet_is_finished() whatever permission the organisation
      -- puts on the move. Neither is a button.
      ('count_sheet',        'issue',                  'routine', 'erp.raise_count_tasks(text)'),
      ('count_sheet',        'close',                  'routine', 'erp.close_count_sheet_when_finished(uuid)'),

      -- ── The base content pack's own document lifecycles ───────────────────
      -- Installed by applying the base pack rather than by a module installer
      -- (20260903160000, Starter Content Packs §5.1): the five nothing else
      -- creates, less the transfer order above, which only the inventory
      -- installer ships since 20260928200000 (D8). None of them is left to a
      -- door, so the document page draws every move each one declares. An
      -- organisation that applied the pack before then keeps them.
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
   -- Version 1 of the transfer order's moves that version 2 does not declare
   -- are kept only while a version in use declares them (20260928200000): an
   -- organisation still on version 1, or a transfer still on it. Once none is,
   -- the rows go, and the register reads as version 2's alone.
   -- And version 1 of the stock adjustment's one move version 2 does not
   -- declare, the same way (20260928500000).
   where not ((x.machine_code = 'transfer_order'
               and x.transition_code in ('approved', 'closed',
                                         'draft_to_discrepancy', 'approved_to_discrepancy', 'issued_to_discrepancy',
                                         'in_transit_to_discrepancy', 'received_to_discrepancy', 'discrepancy_to_received',
                                         'draft_to_cancelled', 'approved_to_cancelled', 'issued_to_cancelled',
                                         'in_transit_to_cancelled', 'received_to_cancelled'))
              or (x.machine_code = 'stock_adjustment'
                  and x.transition_code = 'approved_to_cancelled'))
      or erp.transition_in_use(x.machine_code, x.transition_code)
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D1. Version 1, for the suites that walk documents in flight on it
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.stock_adjustment_v1_item()
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- Version 1 of the stock adjustment's lifecycle, as inventory-operations 5
  -- shipped it (20260918810000) and the upgrade register still holds it
  -- (20260928500000). For the suites that walk documents in flight on it.
  select ui.payload
    from erp_ref.module_upgrade_item ui
   where ui.install_code = 'inventory-operations' and ui.to_version = 5
     and ui.object_kind = 'state_machine' and ui.object_key = 'stock_adjustment'
$$;

revoke all on function erp_test.stock_adjustment_v1_item() from public, anon;

comment on function erp_test.stock_adjustment_v1_item() is
  'Version 1 of the stock adjustment''s lifecycle, from the upgrade register (20260928500000).';

create or replace function erp_test.stock_adjustment_on_version_1()
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_cs uuid;
  v_version uuid;
begin
  -- Puts the organisation's stock adjustments back on version 1 of their
  -- lifecycle, as one configured before 20260928500000 holds it, through a
  -- change set promoted the way an upgrade promotes one. Documents raised
  -- after start on it. For a suite, inside its rolled-back block, in an
  -- organisation not yet live.
  v_cs := erp.create_change_set(
    format('zz-stock-adjustment-v1-%s', substr(md5(gen_random_uuid()::text), 1, 8)),
    'Stock adjustment, version 1',
    'Version 1 of the stock adjustment''s lifecycle, for a suite that walks documents in flight on it.');
  perform erp.add_change_set_item(v_cs, 'state_machine', 'stock_adjustment',
                                  erp_test.stock_adjustment_v1_item(), 'upsert', null,
                                  'version 1 of the stock adjustment''s lifecycle');
  perform erp.submit_change_set(v_cs);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);

  select v.id into v_version
    from erp.state_machine m
    join erp.state_machine_version v on v.tenant_id = m.tenant_id and v.state_machine_id = m.id
   where m.tenant_id = erp.require_tenant_id() and m.code = 'stock_adjustment' and v.status = 'active'
   order by v.version desc
   limit 1;
  return v_version;
end;
$$;

revoke all on function erp_test.stock_adjustment_on_version_1() from public, anon;

comment on function erp_test.stock_adjustment_on_version_1() is
  'Puts the organisation''s stock adjustments back on version 1 of their lifecycle through a promoted '
  'change set, for a suite (20260928500000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- D2. The suites version 2 changes the answer for
--
-- M1's suite walks version 1's adjustments, which is what it proves. The
-- transfer order and site transfer suites read the installer at version 8
-- or later, and plan only the transfer order's items. The count adjustment
-- suite's cases 6, 18 and 24 are re-pinned deliberately, as its header
-- asked: a count's adjustment is approved by approve_with_count, and a
-- hand-typed COUNT_VARIANCE is refused. The demonstration's Saturday
-- write-down is a damaged unit. Each keeps its cases.
-- ─────────────────────────────────────────────────────────────────────────────

do $ssg$
declare
  v_sig constant text := 'erp_test.stock_state_guard_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$    perform erp_test.transfer_order_on_version_1();
$o$;
  b0 constant text := $n$    perform erp_test.transfer_order_on_version_1();
    -- And its adjustments version 1's (20260928500000); version 2 is
    -- erp_test.stock_adjustment_suite's.
    perform erp_test.stock_adjustment_on_version_1();
$n$;
  a1 constant text := $o$                   where m.tenant_id = r.tenant_id and m.code in ('transfer_order', 'stock_adjustment')) = 3;$o$;
  b1 constant text := $n$                   where m.tenant_id = r.tenant_id and m.code in ('transfer_order', 'stock_adjustment')) = 4;
    -- Four since 20260928500000: the stock adjustment's version 2 as
    -- installed, and version 1 again, as for the transfer order.$n$;
  n integer;
begin
  if position('erp_test.stock_adjustment_on_version_1()' in v_def) > 0 then
    raise notice '% already walks version 1 of the adjustment; left as it is', v_sig;
    return;
  end if;
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a0, ''))) / length(a0),
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % version anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(v_def, a0, b0), a1, b1);
end
$ssg$;

do $tos$
declare
  v_sig constant text := 'erp_test.transfer_order_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$                    where i.tenant_id = r.tenant_id and i.install_code = 'inventory-operations') = 8, false);$o$;
  b0 constant text := $n$                    -- 8 or later: 9 since 20260928500000, the stock adjustment's.
                    where i.tenant_id = r.tenant_id and i.install_code = 'inventory-operations') >= 8, false);$n$;
  a1 constant text := $o$                    where i.tenant_id = r.tenant_id and i.install_code = 'inventory-operations') = 8
              and (select dt.approval_chain_code from erp.document_type dt$o$;
  b1 constant text := $n$                    where i.tenant_id = r.tenant_id and i.install_code = 'inventory-operations') >= 8
              and (select dt.approval_chain_code from erp.document_type dt$n$;
  a2 constant text := $o$      from erp.plan_module_upgrade('inventory-operations') p;$o$;
  b2 constant text := $n$      from erp.plan_module_upgrade('inventory-operations') p
     -- The transfer order's; version 9 plans the stock adjustment's too
     -- (20260928500000).
     where p.object_key like 'transfer_order%';$n$;
  n integer;
begin
  if position('9 since 20260928500000' in v_def) > 0 then
    raise notice '% already reads a later version; left as it is', v_sig;
    return;
  end if;
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a0, ''))) / length(a0),
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1),
      (length(v_def) - length(replace(v_def, a2, ''))) / length(a2)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % version anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(replace(v_def, a0, b0), a1, b1), a2, b2);
end
$tos$;

do $sts$
declare
  v_sig constant text := 'erp_test.site_transfer_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$              where i.tenant_id = v_tenant and i.install_code = 'inventory-operations') = 8;$o$;
  b0 constant text := $n$              -- 8 or later: 9 since 20260928500000, the stock adjustment's.
              where i.tenant_id = v_tenant and i.install_code = 'inventory-operations') >= 8;$n$;
  n integer;
begin
  if position('9 since 20260928500000' in v_def) > 0 then
    raise notice '% already reads a later version; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, a0, ''))) / length(a0);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % version anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, a0, b0);
end
$sts$;

do $cadj$
declare
  v_sig constant text := 'erp_test.count_adjustment_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  -- Case 6: the organisation's permission moved onto the count's approve.
  a0 constant text := $o$             case when tr.code = 'approve' then 'inventory.zz_cadj_approve' else tr.required_permission end,$o$;
  b0 constant text := $n$             case when tr.code in ('approve', 'approve_with_count') then 'inventory.zz_cadj_approve' else tr.required_permission end,$n$;
  a1 constant text := $o$         and l.transition_code = 'approve';
      select count(*) into v_n2 from erp.approval_request ar$o$;
  b1 constant text := $n$         and l.transition_code = 'approve_with_count';
      select count(*) into v_n2 from erp.approval_request ar$n$;
  a2 constant text := $o$             count(*) filter (where tr.code = 'approve' and fs.is_initial and fs.code = 'draft')$o$;
  b2 constant text := $n$             count(*) filter (where tr.code = 'approve_with_count' and fs.is_initial and fs.code = 'draft')$n$;
  a3 constant text := $o$    return query select 'a count''s adjustment is approved past a permission moved onto the approve and a chain named on the type, because its lifecycle has no submit',
      v_err is null and v_n = 1 and v_state = 'posted'$o$;
  b3 constant text := $n$    -- Re-pinned by 20260928500000 (PR11 M4, D9), as the header asked: the
    -- lifecycle has a submit now, and the count's approve is its own move,
    -- approve_with_count, derived from the count's approval. The chain the
    -- organisation names is still not asked of a count's adjustment,
    -- because the count's route never submits: the count's approval is the
    -- adjustment's. The type names the value chain as installed.
    return query select 'a count''s adjustment is approved with its count past a permission moved onto the approve and a chain named on the type: the count''s route never submits, and the approval is the count''s',
      v_err is null and v_n = 1 and v_state = 'posted'$n$;
  a4 constant text := $o$      and v_n2 = 0 and v_n3 = 0 and v_n4 = 1
      and (select dt.approval_chain_code from erp.document_type dt
            where dt.tenant_id = r.tenant_id and dt.code = 'stock_adjustment') is null,$o$;
  b4 constant text := $n$      and v_n2 = 0 and v_n3 = 1 and v_n4 = 1
      and (select dt.approval_chain_code from erp.document_type dt
            where dt.tenant_id = r.tenant_id and dt.code = 'stock_adjustment') = 'stock_adjustment_value',$n$;
  a5 constant text := $o$        format('%s approve moved; adjustment %s; derived %s; %s approval request(s); %s submit(s); approve from draft %s',$o$;
  b5 constant text := $n$        format('%s approve moved; adjustment %s; derived %s; %s approval request(s); %s submit(s); approve with its count from draft %s',$n$;
  -- Case 18.
  a6 constant text := $o$    select count(*) filter (where l.transition_code = 'approve'
                              and l.guard_data #>> '{derived,fact}' = 'erp.count_task_is_approved'),$o$;
  b6 constant text := $n$    -- approve_with_count since 20260928500000.
    select count(*) filter (where l.transition_code = 'approve_with_count'
                              and l.guard_data #>> '{derived,fact}' = 'erp.count_task_is_approved'),$n$;
  -- Case 24: a hand-typed adjustment of consigned stock, under a reason of
  -- its own now that COUNT_VARIANCE is the count's; raised empty so its
  -- owner is set before it is submitted, and posted as it is submitted.
  a7 constant text := $o$    -- 24. The free-hand door costs only what the company owns, and derives
    --     nothing. A hand-typed COUNT_VARIANCE is still taken (PR11, I5).
    v_fixture := 'a hand-typed adjustment of consigned stock';
    res := erp.raise_stock_adjustment(v_site, 'COUNT_VARIANCE',
             jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -1, 'location_id', v_loc)),
             null, null, 'ZZ-CADJ-' || v_hex);
    v_doc := (res ->> 'document_id')::uuid;
    perform erp.set_document_stock_owner(v_doc, v_sup);
    perform set_config('erp.deriving_move', v_doc::text || ':approve', true);
    v_fact := erp.derived_move_fact('document', v_doc, 'approve');
    perform set_config('erp.deriving_move', '', true);
    perform erp.transition_document(v_doc, 'approve', 'suite');
    res := erp.post_stock_adjustment(v_doc);
$o$;
  b7 constant text := $n$    -- 24. The free-hand door costs only what the company owns, and derives
    --     nothing from a count. Re-pinned by 20260928500000 (PR11 M4, D11):
    --     a hand-typed COUNT_VARIANCE is refused, so the hand-typed one gives
    --     a reason of its own; it is raised empty, its owner set, its line
    --     added, and submitted, which posts it within the threshold.
    v_fixture := 'a hand-typed adjustment of consigned stock';
    begin
      perform erp.raise_stock_adjustment(v_site, 'COUNT_VARIANCE',
                jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -1, 'location_id', v_loc)),
                null, null, 'ZZ-CADJ-' || v_hex);
      v_err3 := 'went through';
    exception when others then v_err3 := sqlerrm; end;
    res := erp.raise_stock_adjustment(v_site, 'SAMPLE', '[]'::jsonb, null,
             'one taken for the lab', 'ZZ-CADJ-' || v_hex);
    v_doc := (res ->> 'document_id')::uuid;
    perform erp.set_document_stock_owner(v_doc, v_sup);
    perform erp.add_document_line(v_doc, v_item, -1, 0, null, null);
    update erp.document_line set location_id = v_loc where tenant_id = r.tenant_id and document_id = v_doc;
    perform set_config('erp.deriving_move', v_doc::text || ':approve_with_count', true);
    v_fact := erp.derived_move_fact('document', v_doc, 'approve_with_count');
    perform set_config('erp.deriving_move', '', true);
    perform erp.transition_document(v_doc, 'submit', 'suite');
    select jsonb_build_object('state', erp.document_state_code(v_doc),
             'cost_minor', coalesce(sum(m.cost_minor), 0),
             -- A movement worth nothing raises no journal.
             'journals', count(*) filter (where coalesce(m.cost_minor, 0) <> 0))
      into res
      from erp.stock_movement m where m.tenant_id = r.tenant_id and m.document_id = v_doc;
$n$;
  a8 constant text := $o$                     and m.owner_party_id = v_sup and m.cost_minor is null and m.reason_code = 'COUNT_VARIANCE')$o$;
  b8 constant text := $n$                     and m.owner_party_id = v_sup and m.cost_minor is null and m.reason_code = 'SAMPLE')
      and res ->> 'state' = 'posted'
      and v_err3 like 'CLOVEERP_COUNT_VARIANCE_IS_A_COUNTS%'$n$;
  n integer;
begin
  if position('Re-pinned by 20260928500000' in v_def) > 0 then
    raise notice '% already re-pinned for version 2; left as it is', v_sig;
    return;
  end if;
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a0, ''))) / length(a0),
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1),
      (length(v_def) - length(replace(v_def, a2, ''))) / length(a2),
      (length(v_def) - length(replace(v_def, a3, ''))) / length(a3),
      (length(v_def) - length(replace(v_def, a4, ''))) / length(a4),
      (length(v_def) - length(replace(v_def, a5, ''))) / length(a5),
      (length(v_def) - length(replace(v_def, a6, ''))) / length(a6),
      (length(v_def) - length(replace(v_def, a7, ''))) / length(a7),
      (length(v_def) - length(replace(v_def, a8, ''))) / length(a8)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % re-pin anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  v_def := replace(v_def, a0, b0);
  v_def := replace(v_def, a1, b1);
  v_def := replace(v_def, a2, b2);
  v_def := replace(v_def, a3, b3);
  v_def := replace(v_def, a4, b4);
  v_def := replace(v_def, a5, b5);
  v_def := replace(v_def, a6, b6);
  v_def := replace(v_def, a7, b7);
  v_def := replace(v_def, a8, b8);
  execute v_def;
end
$cadj$;

do $dhs$
declare
  v_sig constant text := 'erp_test.demo_history_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$              or m.reason_code <> 'COUNT_VARIANCE'
$o$;
  b0 constant text := $n$              -- A damaged unit since 20260928500000: a COUNT_VARIANCE is
              -- the count's own, and a past Saturday is not counted today.
              or m.reason_code <> 'DAMAGE_STORAGE'
$n$;
  n integer;
begin
  if position('A damaged unit since 20260928500000' in v_def) > 0 then
    raise notice '% already expects a damaged unit; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, a0, ''))) / length(a0);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % weekend reason anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, a0, b0);
end
$dhs$;

do $fifo$
declare
  v_sig constant text := 'erp_test.fifo_is_costed_from_its_layers_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$    v_doc := (v_res ->> 'document_id')::uuid;
    perform erp.transition_document(v_doc, 'approve', 'suite');
    v_res := erp.post_stock_adjustment(v_doc);
$o$;
  b0 constant text := $n$    v_doc := (v_res ->> 'document_id')::uuid;
    -- Posted as it is raised since 20260928500000: nobody need approve it
    -- while the organisation has set no threshold.
$n$;
  a1 constant text := $o$                       and (v_res ->> 'cost_minor')::bigint = -2000
                       and (v_res ->> 'journals')::integer = 1
$o$;
  b1 constant text := $n$                       and (v_res ->> 'state') = 'posted'
$n$;
  a2 constant text := $o$    detail := format('movement at %s costing %s; inventory up %s; the adjustment says %s through %s journal(s); F now %s a unit',
                     v_unit, v_cost, v_after - v_before, v_res ->> 'cost_minor',
                     v_res ->> 'journals', erp.unit_cost_at(v_f, v_site));$o$;
  b2 constant text := $n$    detail := format('movement at %s costing %s; inventory up %s; the adjustment is %s; F now %s a unit',
                     v_unit, v_cost, v_after - v_before, v_res ->> 'state', erp.unit_cost_at(v_f, v_site));$n$;
  n integer;
begin
  if position('Posted as it is raised since 20260928500000' in v_def) > 0 then
    raise notice '% already expects the adjustment posted as it is raised; left as it is', v_sig;
    return;
  end if;
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a0, ''))) / length(a0),
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1),
      (length(v_def) - length(replace(v_def, a2, ''))) / length(a2)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % adjustment anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(replace(v_def, a0, b0), a1, b1), a2, b2);
end
$fifo$;

-- A transfer waiting for approval is rejected by its approver, or withdrawn
-- by its raiser, and by nobody else who may move stock (20260928500000).
do $tos_reject$
declare
  v_sig constant text := 'erp_test.transfer_order_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$  v_owner   text := current_user;
begin
$o$;
  b0 constant text := $n$  v_owner   text := current_user;
  a_nm      uuid := gen_random_uuid();   -- moves stock anywhere, and is asked nothing
  t_rj      uuid;
begin
$n$;
  a1 constant text := $o$    -- ── 16. Issued is the despatch's ────────────────────────────────────────
$o$;
  b1 constant text := $n$    -- ── 15b. A rejection is the approver's, or the raiser's withdrawal ──────
    -- (20260928500000, found by the PR11 M6 walk.)
    v_fixture := 'who rejects';
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    -- A role is configuration: made while the organisation is briefly not
    -- live, as case 17 takes the chain off the type.
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    insert into erp.role (tenant_id, code, name, status)
    values (r.tenant_id, 'zz_mover', 'Mover, asked nothing', 'active') returning id into v_line;
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    values (r.tenant_id, v_line, 'inventory.move'), (r.tenant_id, v_line, 'inventory.read');
    res := public.erp_invite_principal('nm@zz-tos-' || v_hex || '.test', 'Nat Mover');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'zz_mover', null, null, 'moves stock, approves nothing');
    perform set_config('request.jwt.claims', json_build_object('sub', a_nm)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    update erp.environment set is_live = true where tenant_id = r.tenant_id and is_self;
    perform set_config('request.jwt.claims', json_build_object('sub', a_mov)::text, true);
    t_rj := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 5))) ->> 'document_id')::uuid;
    perform set_config('request.jwt.claims', json_build_object('sub', a_nm)::text, true);
    v_got  := erp_test.stock_state_try(t_rj, 'reject');
    select x ->> 'refused' into v_got4
      from jsonb_array_elements(public.erp_available_transitions(t_rj)) x where x ->> 'code' = 'reject';
    perform set_config('request.jwt.claims', json_build_object('sub', a_app)::text, true);
    v_got2 := erp_test.stock_state_try(t_rj, 'reject');
    select coalesce(x ->> 'refused', 'none') into v_got5
      from jsonb_array_elements(public.erp_available_transitions(t_rj)) x where x ->> 'code' = 'reject';
    perform set_config('request.jwt.claims', json_build_object('sub', a_mov)::text, true);
    v_got3 := public.erp_transition_document(t_rj, 'reject', 'raised by mistake') ->> 'state';
    case_name := 'a transfer waiting for approval is rejected by the approver it asked and withdrawn by its raiser, and somebody else who may move stock is refused and offered nothing';
    passed := coalesce(v_got like 'CLOVEERP_REJECT_IS_THE_APPROVERS%'
              and v_got4 = 'CLOVEERP_REJECT_IS_THE_APPROVERS'
              and v_got2 = 'went through' and v_got5 = 'none'
              and v_got3 = 'draft', false);
    detail := format('the mover asked nothing: %s, offered as %s; the approver: %s, refused %s; the raiser withdrew it to %s',
                     left(v_got, 60), coalesce(v_got4, 'nothing'), v_got2, v_got5, v_got3);
    return next;

    -- ── 16. Issued is the despatch's ────────────────────────────────────────
$n$;
  a2 constant text := $o$  if v_total <> 20 then
    raise exception 'CLOVEERP_TRANSFER_ORDER_SUITE_SHRANK: % case(s), expected 20; the fixture stopped %', v_total,$o$;
  b2 constant text := $n$  -- 21 since 20260928500000: who rejects.
  if v_total <> 21 then
    raise exception 'CLOVEERP_TRANSFER_ORDER_SUITE_SHRANK: % case(s), expected 21; the fixture stopped %', v_total,$n$;
  v_asig constant text := 'erp_test.assert_transfer_order_suite()';
  v_adef text := pg_get_functiondef(v_asig::regprocedure);
  n integer;
begin
  if position('who rejects' in v_def) = 0 then
    foreach n in array array[
        (length(v_def) - length(replace(v_def, a0, ''))) / length(a0),
        (length(v_def) - length(replace(v_def, a1, ''))) / length(a1)] loop
      if n <> 1 then
        raise exception 'CLOVEERP_ANCHOR_MOVED: % rejection anchor found % time(s)', v_sig, n;
      end if;
    end loop;
    execute replace(replace(v_def, a0, b0), a1, b1);
  end if;
  if position('21 since 20260928500000' in v_adef) = 0 then
    n := (length(v_adef) - length(replace(v_adef, a2, ''))) / length(a2);
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % count anchor found % time(s)', v_asig, n;
    end if;
    execute replace(v_adef, a2, b2);
  end if;
end
$tos_reject$;

-- ─────────────────────────────────────────────────────────────────────────────
-- E1. The proof: erp_test.stock_adjustment_suite, restated for version 2
--
-- An organisation installed today, with one site, a hundred at 500 and a
-- layered product, and five people: the administrator; a stock counter who
-- may adjust stock and not post to the ledger; a writer-off who may only
-- write off; and two of the inventory role, one who raises and one who
-- approves. Every case of the suite this replaces is kept, walked the way
-- version 2 walks it (raised, and so posted), and the cases version 2 adds
-- follow: the threshold, the reason, COUNT_VARIANCE, the write-off, the
-- count's approve, My approvals, and version 1 in flight.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.stock_adjustment_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_hex     text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1        uuid := gen_random_uuid();   -- the administrator
  a_cnt     uuid := gen_random_uuid();   -- adjusts stock, may not post to the ledger
  a_wo      uuid := gen_random_uuid();   -- may only write off
  a_mov     uuid := gen_random_uuid();   -- the inventory role, raises
  a_app     uuid := gen_random_uuid();   -- the inventory role, approves
  r         record;
  res       jsonb;
  v_ccy     char(3);
  v_uom     uuid; v_item uuid; v_fifo uuid; v_item2 uuid;
  v_site    uuid; v_bulk uuid;
  v_role    uuid; v_app uuid; v_mov uuid;
  v_when    date;
  v_adj uuid; v_found uuid; v_v1 uuid; v_theft uuid; v_empty uuid;
  v_small uuid; v_big uuid; v_rt uuid; v_edit uuid; v_mya uuid; v_myr uuid; v_wo uuid; v_wo_big uuid;
  v_line    uuid; v_task uuid;
  v_mv      bigint; v_mv2 bigint;
  v_period  uuid; v_was text;
  v_codes   text; v_bad text;
  v_got text; v_got2 text; v_got3 text; v_got4 text; v_got5 text; v_got6 text;
  v_n integer; v_n2 integer;
  v_q numeric; v_mv_at timestamptz; v_jr_on date;
  v_adj_minor bigint; v_inv_minor bigint; v_issue bigint; v_write bigint; v_val bigint; v_ledger bigint;
  v_ok      boolean;
  v_fixture text;
  v_owner   text := current_user;
begin
  begin
    v_fixture := 'provisioning';
    select * into r from erp.provision_tenant(
      'zz-sas-' || v_hex, 'Stock adjustment suite',
      'a@zz-sas-' || v_hex || '.test', 'Suite Admin');
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    v_fixture := 'installing';
    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);
    select e.base_currency into v_ccy from erp.entity e where e.id = r.entity_id;

    v_fixture := 'a site and its stock';
    insert into erp.site (tenant_id, entity_id, code, name, site_type, country_code, status)
    values (r.tenant_id, r.entity_id, 'ZZ-ADJ', 'Adjustment depot', 'warehouse', 'GB', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
    values (r.tenant_id, v_site, 'ZZ-ADJ-BULK', 'Adjustment bulk', 'bulk', true, 'active') returning id into v_bulk;
    insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
    values (r.tenant_id, v_site, 'ZZ-ADJ-IN', 'Adjustment goods in', 'receiving', false, 'active');
    select u.id into v_uom from erp.uom u where u.tenant_id = r.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'ZZ-ADJ-1', 'Countable widget', v_uom, 'active') returning id into v_item;
    perform erp.receive_cost(v_item, v_site, 100, 500, v_ccy);
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, to_location_id,
      to_status, quantity, uom_id, unit_cost_minor, currency, reason_code)
    values (r.tenant_id, r.entity_id, v_site, 'receipt_no_order', v_item, v_bulk, 'available', 100, v_uom, 500,
      v_ccy, 'OPENING');

    v_fixture := 'the people';
    insert into erp.role (tenant_id, code, name, status)
    values (r.tenant_id, 'zz_counter', 'Stock counter', 'active') returning id into v_role;
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    values (r.tenant_id, v_role, 'inventory.adjust'), (r.tenant_id, v_role, 'inventory.read');
    insert into erp.role (tenant_id, code, name, status)
    values (r.tenant_id, 'zz_writer_off', 'Writer-off', 'active') returning id into v_role;
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    values (r.tenant_id, v_role, 'inventory.write_off'), (r.tenant_id, v_role, 'inventory.read');
    res := public.erp_invite_principal('counter@zz-sas-' || v_hex || '.test', 'Stock Counter');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'zz_counter', null, null, 'adjusts stock');
    perform set_config('request.jwt.claims', json_build_object('sub', a_cnt)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('writer@zz-sas-' || v_hex || '.test', 'Wren Writer');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'zz_writer_off', null, null, 'writes stock off');
    perform set_config('request.jwt.claims', json_build_object('sub', a_wo)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('mover@zz-sas-' || v_hex || '.test', 'Mo Mover');
    v_mov := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(v_mov, 'inventory', null, null, 'raises adjustments');
    perform set_config('request.jwt.claims', json_build_object('sub', a_mov)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('approver@zz-sas-' || v_hex || '.test', 'Ada Approver');
    v_app := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(v_app, 'inventory', null, null, 'approves adjustments');
    perform set_config('request.jwt.claims', json_build_object('sub', a_app)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- ── 1. Installed today, it is version 2 ─────────────────────────────────
    v_fixture := 'the install';
    select string_agg(t.code, ',' order by t.code),
           count(*) filter (where t.required_permission is distinct from 'inventory.adjust')
      into v_codes, v_n
      from erp.state_machine m
      join erp.state_machine_version v on v.tenant_id = m.tenant_id and v.state_machine_id = m.id and v.status = 'active'
      join erp.transition t on t.tenant_id = v.tenant_id and t.state_machine_version_id = v.id
     where m.tenant_id = r.tenant_id and m.code = 'stock_adjustment';
    select string_agg(s.code, ',' order by s.code) into v_bad
      from erp.state_machine m
      join erp.state_machine_version v on v.tenant_id = m.tenant_id and v.state_machine_id = m.id and v.status = 'active'
      join erp.state s on s.tenant_id = v.tenant_id and s.state_machine_version_id = v.id
     where m.tenant_id = r.tenant_id and m.code = 'stock_adjustment'
       and not s.is_initial
       and not exists (select 1 from erp.transition t where t.state_machine_version_id = v.id and t.to_state_id = s.id);
    select string_agg(format('%s/%s/%s', st.code, rl.code, st.condition), ',') into v_got
      from erp.approval_chain ac
      join erp.approval_chain_version acv on acv.tenant_id = ac.tenant_id and acv.approval_chain_id = ac.id and acv.status = 'active'
      join erp.approval_step st on st.tenant_id = acv.tenant_id and st.approval_chain_version_id = acv.id
      left join erp.role rl on rl.id = st.role_id
     where ac.tenant_id = r.tenant_id and ac.code = 'stock_adjustment_value'
       and acv.value_field = 'value_at_cost_minor';
    select string_agg(t.code, ',' order by t.code) into v_got2
      from erp.state_machine m
      join erp.state_machine_version v on v.tenant_id = m.tenant_id and v.state_machine_id = m.id and v.status = 'active'
      join erp.transition t on t.tenant_id = v.tenant_id and t.state_machine_version_id = v.id
      join erp.state fs on fs.id = t.from_state_id
     where m.tenant_id = r.tenant_id and m.code = 'count_task_lifecycle' and fs.code = 'approved';
    case_name := 'a new organisation installs version 2 of the stock adjustment: eight moves, each asking inventory.adjust, every state entered, a value chain for the inventory role that asks nobody until a threshold is set, and a count task that can be put back from approved';
    passed := coalesce(v_codes = 'approve,approve_with_count,approve_within_threshold,cancel,cancel_approved,post,reject,submit'
              and v_n = 0 and v_bad is null
              and v_got = 'stock_controller/inventory/false'
              and v_got2 = 'cancel_approved,post'
              and (select dt.approval_chain_code from erp.document_type dt
                    where dt.tenant_id = r.tenant_id and dt.code = 'stock_adjustment') = 'stock_adjustment_value'
              and (select i.installer_version from erp.module_installation i
                    where i.tenant_id = r.tenant_id and i.install_code = 'inventory-operations') = 9, false);
    detail := format('moves %s; %s without inventory.adjust; states with no way in: %s; chain steps %s; a count leaves approved by %s',
                     coalesce(v_codes, 'none'), v_n, coalesce(v_bad, 'none'), coalesce(v_got, 'none'), coalesce(v_got2, 'nothing'));
    return next;

    -- ── 2. An organisation on version 8 takes version 9 from the register ───
    v_fixture := 'back to version 8';
    perform erp_test.stock_adjustment_on_version_1();
    update erp.document_type set approval_chain_code = null
     where tenant_id = r.tenant_id and code = 'stock_adjustment';
    update erp.approval_chain set code = 'zz_before_' || v_hex, status = 'inactive'
     where tenant_id = r.tenant_id and code = 'stock_adjustment_value';
    update erp.module_installation set installer_version = 8
     where tenant_id = r.tenant_id and install_code = 'inventory-operations';
    v_v1 := (erp.raise_stock_adjustment(v_site, 'DAMAGE_STORAGE',
               jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -2, 'location_id', v_bulk)),
               null, 'a pallet went over', 'ZZ-V1') ->> 'document_id')::uuid;
    v_got2 := erp.document_state_code(v_v1);
    -- A write-off on version 1 writes its scrap as it always did.
    v_mv := erp.write_off_stock(v_item, v_site, v_bulk, 1, 'scuffed before the upgrade');
    v_fixture := 'the upgrade';
    select string_agg(p.object_kind || ':' || p.object_key, ',' order by p.object_kind, p.object_key) into v_got
      from erp.plan_module_upgrade('inventory-operations') p
     where p.object_key in ('stock_adjustment', 'stock_adjustment_value');
    res := erp.upgrade_module_configuration('inventory-operations');
    v_adj := (erp.raise_stock_adjustment(v_site, 'DAMAGE_STORAGE',
               jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -1, 'location_id', v_bulk)),
               null, 'one dropped', 'ZZ-V2') ->> 'document_id')::uuid;
    case_name := 'an organisation on version 8 is offered the lifecycle, the chain and the type, writes off as it always did until it takes them, and an adjustment raised after is version 2''s, posted as it is raised';
    passed := coalesce(v_got = 'approval_chain:stock_adjustment_value,document_type:stock_adjustment,state_machine:stock_adjustment'
              and (res ->> 'promoted')::boolean
              and v_got2 = 'draft'
              and exists (select 1 from erp.stock_movement m
                           where m.id = v_mv and m.movement_type = 'scrap' and m.document_id is null)
              and erp.document_state_code(v_adj) = 'posted'
              and erp.document_declares_move(v_v1, 'approve')
              and not erp.document_declares_move(v_v1, 'submit')
              and (select i.installer_version from erp.module_installation i
                    where i.tenant_id = r.tenant_id and i.install_code = 'inventory-operations') = 9
              and (select dt.approval_chain_code from erp.document_type dt
                    where dt.tenant_id = r.tenant_id and dt.code = 'stock_adjustment') = 'stock_adjustment_value', false);
    detail := format('planned %s; %s; a version 1 adjustment raised before stood %s, and a write-off wrote movement %s; one raised after is %s',
                     coalesce(v_got, 'nothing'), res, v_got2, coalesce(v_mv::text, 'none'), erp.document_state_code(v_adj));
    return next;

    -- ── 3. A version 1 adjustment in flight moves as it did ────────────────
    v_fixture := 'version 1 in flight';
    perform erp.transition_document(v_v1, 'approve', 'approved the way version 1 is');
    v_got := erp.document_state_code(v_v1);
    v_n := (select count(*) from erp.stock_movement m where m.tenant_id = r.tenant_id and m.document_id = v_v1);
    begin
      perform erp.add_document_line(v_v1, v_item, -50, 0, null, null);
      v_got2 := 'went through';
    exception when others then v_got2 := sqlerrm; end;
    select l.id into v_line from erp.document_line l where l.tenant_id = r.tenant_id and l.document_id = v_v1;
    begin
      perform erp.amend_document_line(v_line, -30, 'made bigger after its approval');
      v_got3 := 'went through';
    exception when others then v_got3 := sqlerrm; end;
    res := erp.post_stock_adjustment(v_v1);
    case_name := 'a version 1 adjustment in flight is approved by its own click and is not posted by it, takes no new line and no amendment once approved, and Confirm posts it';
    passed := coalesce(v_got = 'approved' and v_n = 0
              and v_got2 like 'CLOVEERP_ADJUSTMENT_CHANGED_ONLY_AS_A_DRAFT%'
              and v_got3 like 'CLOVEERP_PAST_AMENDMENT_CUT_OFF: adjustment_submitted%'
              and res ->> 'state' = 'posted' and (res ->> 'missing')::numeric = 2, false);
    detail := format('approved to %s with %s movement(s); a new line: %s; amended: %s; confirmed %s',
                     v_got, v_n, left(v_got2, 70), left(v_got3, 70), res ->> 'state');
    return next;

    -- ── 4. With no threshold set, a backdated adjustment posts as it is raised
    v_fixture := 'raising a backdated adjustment';
    v_when := current_date - 20;
    res := erp.raise_stock_adjustment(v_site, 'DAMAGE_STORAGE',
             jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -10, 'location_id', v_bulk)),
             v_when, 'A pallet went over in the racking', 'ZZ-COUNT-1');
    v_adj := (res ->> 'document_id')::uuid;
    select string_agg(l.transition_code || coalesce('[' || (l.guard_data -> 'derived' ->> 'fact') || ']', ''), ',' order by l.id)
      into v_codes
      from erp.state_transition_log l where l.tenant_id = r.tenant_id and l.object_id = v_adj;
    select string_agg(q.status::text || ' ' || coalesce(q.context ->> 'value_at_cost_minor', '-') || ' '
                      || (select count(*) from erp.approval_task t where t.approval_request_id = q.id and t.status <> 'skipped'), ';')
      into v_got
      from erp.approval_request q where q.tenant_id = r.tenant_id and q.object_id = v_adj;
    select m.occurred_at into v_mv_at
      from erp.stock_movement m where m.tenant_id = r.tenant_id and m.document_id = v_adj and not m.is_reversal
     order by m.id limit 1;
    -- The journal the movement raised, found by its date: an adjustment's
    -- journal carries no document.
    select max(j.posting_date) into v_jr_on
      from erp.journal j
     where j.tenant_id = r.tenant_id and j.source_code = 'stock.adjusted' and j.status = 'posted'
       and j.posting_date < current_date;
    case_name := 'with no threshold set, an adjustment dated twenty days ago is posted as it is raised: submitted, approved within its threshold because nobody was asked, and posted by the approval, its movement and journal both dated that day';
    passed := coalesce(res ->> 'state' = 'posted'
              and v_codes = 'submit,approve_within_threshold[erp.approval_asked_nobody],post[erp.adjustment_is_approved]'
              and v_got = 'approved 5000 0'
              and (res ->> 'adjusted_on')::date = v_when and (res ->> 'reason_code') = 'DAMAGE_STORAGE'
              and v_mv_at::date = v_when and v_jr_on = v_when
              and (select coalesce(sum(b.quantity), 0) from erp.stock_balance b
                    where b.tenant_id = r.tenant_id and b.site_id = v_site) = 86, false);
    detail := format('raised %s; moves %s; request %s; movement at %s, journal on %s',
                     res ->> 'state', v_codes, coalesce(v_got, 'none'), v_mv_at, v_jr_on);
    return next;

    -- ── 5. The write-off reaches the stock adjustments account ──────────────
    v_fixture := 'reading the stock adjustments account';
    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)::bigint into v_adj_minor
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = r.tenant_id and j.status = 'posted' and a.code = erp.tenant_account_code('stock_adjustment');
    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)::bigint into v_inv_minor
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = r.tenant_id and j.status = 'posted' and a.code = erp.tenant_account_code('inventory');
    case_name := 'fourteen written off, thirteen adjusted and one scrapped, are a cost at what they cost, on the stock adjustments account and off inventory, and the movement carries the adjustment''s reason';
    passed := v_adj_minor = 7000 and v_inv_minor = -7000
          and exists (select 1 from erp.stock_movement m
                       where m.tenant_id = r.tenant_id and m.document_id = v_adj
                         and m.reason_code = 'DAMAGE_STORAGE' and m.movement_type = 'count_adjustment'
                         and m.document_line_id is not null);
    detail := format('stock adjustments %s, inventory %s', v_adj_minor, v_inv_minor);
    return next;

    -- ── 6. Stock found goes the other way ───────────────────────────────────
    v_fixture := 'adjusting stock upwards';
    res := erp.raise_stock_adjustment(v_site, 'FOUND',
             jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 4, 'location_id', v_bulk)),
             v_when + 1, 'Four turned up behind the racking', 'ZZ-COUNT-2');
    v_found := (res ->> 'document_id')::uuid;
    case_name := 'stock found goes the other way, posted as it is raised: four back on the shelf';
    passed := res ->> 'state' = 'posted'
          and (select coalesce(sum(b.quantity), 0) from erp.stock_balance b
                where b.tenant_id = r.tenant_id and b.site_id = v_site) = 90
          and (select coalesce(sum(m.quantity), 0) from erp.stock_movement m
                where m.tenant_id = r.tenant_id and m.document_id = v_found and m.to_location_id is not null) = 4;
    detail := format('%s; %s on hand', res ->> 'state',
                     (select coalesce(sum(b.quantity), 0) from erp.stock_balance b
                       where b.tenant_id = r.tenant_id and b.site_id = v_site));
    return next;

    -- ── 7. A reason that requires approval asks nobody while no threshold is set
    v_fixture := 'a reason that requires approval, and no threshold';
    res := erp.raise_stock_adjustment(v_site, 'THEFT_LOSS',
             jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -1, 'location_id', v_bulk)),
             null, 'One walked out of the loading bay', null);
    v_theft := (res ->> 'document_id')::uuid;
    select q.context ->> 'value_at_cost_minor', q.context ->> 'reason_requires_approval' into v_got, v_got2
      from erp.approval_request q where q.tenant_id = r.tenant_id and q.object_id = v_theft;
    case_name := 'a reason the register says requires approval asks nobody while the organisation has set no threshold, so nothing changes for one that set nothing, and it is valued above any threshold';
    passed := coalesce(res ->> 'state' = 'posted'
              and v_got = '9223372036854775807' and v_got2 = 'true', false);
    detail := format('%s; valued %s; reason requires approval %s', res ->> 'state', coalesce(v_got, 'nothing'), coalesce(v_got2, 'nothing'));
    return next;

    -- ── 8. Backdated behind a later issue ───────────────────────────────────
    -- Thirty at 20 and ten at 60, kept in layers. An issue of thirty takes
    -- the older layer, 600; a write-off of five backdated before it takes five
    -- of the ten at 60, 300. 600 + 300 = 900 = 100 + 800, which a rewind
    -- would have given: the same figure has left the stock ledger.
    v_fixture := 'backdating an adjustment behind a later issue';
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'ZZ-ADJ-2', 'Layered widget', v_uom, 'active') returning id into v_fifo;
    insert into erp.costing_policy (tenant_id, code, name, method, item_id, status)
    values (r.tenant_id, 'zz_adj_fifo', 'Layered widget in layers', 'fifo', v_fifo, 'active');
    perform erp.receive_cost(v_fifo, v_site, 30, 20, v_ccy);
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency, reason_code)
    values (r.tenant_id, r.entity_id, v_site, 'receipt_no_order', v_fifo, v_bulk, 'available', 30, v_uom, 20, v_ccy, 'OPENING');
    perform erp.receive_cost(v_fifo, v_site, 10, 60, v_ccy);
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency, reason_code)
    values (r.tenant_id, r.entity_id, v_site, 'receipt_no_order', v_fifo, v_bulk, 'available', 10, v_uom, 60, v_ccy, 'OPENING');
    v_issue := erp.issue_cost(v_fifo, v_site, 30);
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, from_location_id, from_status,
      quantity, uom_id, unit_cost_minor, currency, reason_code, occurred_at)
    values (r.tenant_id, r.entity_id, v_site, 'emergency_issue', v_fifo, v_bulk, 'available', 30, v_uom, v_issue, v_ccy,
      'SUITE', (current_date - 5)::timestamp at time zone 'UTC')
    returning cost_minor into v_issue;
    res := erp.raise_stock_adjustment(v_site, 'MEASURE_CORRECTION',
             jsonb_build_array(jsonb_build_object('item_id', v_fifo, 'quantity', -5, 'location_id', v_bulk)),
             current_date - 10, 'Measured short ten days ago', 'ZZ-COUNT-3');
    v_adj := (res ->> 'document_id')::uuid;
    select coalesce(sum(m.cost_minor), 0)::bigint, min(m.occurred_at) into v_write, v_mv_at
      from erp.stock_movement m where m.tenant_id = r.tenant_id and m.document_id = v_adj;
    case_name := 'an adjustment backdated behind a later issue leaves that issue''s cost alone and takes what is on the shelf now: 600 then 300, which is the 100 and 800 a rewind would have given, to the penny';
    passed := v_issue = 600 and v_write = 300 and v_mv_at::date = current_date - 10
          and res ->> 'state' = 'posted'
          and (select coalesce(sum(l.remaining * l.unit_cost_minor), 0)::bigint
                 from erp.stock_valuation_layer l where l.tenant_id = r.tenant_id and l.item_id = v_fifo) = 300;
    detail := format('the issue cost %s, the backdated write-off %s, movement dated %s', v_issue, v_write, v_mv_at::date);
    return next;

    -- ── 9. A closed period refuses it ───────────────────────────────────────
    -- Below every door: the journal is dated on the movement, and a closed
    -- period refuses the journal, so the raise that would post it is refused
    -- whole.
    v_fixture := 'closing a period and adjusting into it';
    select fp.id, fp.status::text into v_period, v_was
      from erp.fiscal_period fp
      join erp.ledger l on l.tenant_id = fp.tenant_id and l.id = fp.ledger_id
     where fp.tenant_id = r.tenant_id and l.is_primary
       and (current_date - 40) between fp.starts_on and fp.ends_on
     limit 1;
    update erp.fiscal_period set status = 'closed', closed_at = clock_timestamp()
     where tenant_id = r.tenant_id and id = v_period;
    select count(*) into v_n from erp.document d where d.tenant_id = r.tenant_id;
    begin
      perform erp.raise_stock_adjustment(v_site, 'DAMAGE_STORAGE',
                jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -1, 'location_id', v_bulk)),
                current_date - 40, 'Found short in a month that is shut', 'ZZ-COUNT-4');
      v_got := 'it was accepted';
    exception when others then v_got := sqlerrm; end;
    update erp.fiscal_period set status = v_was::erp.period_status, closed_at = null
     where tenant_id = r.tenant_id and id = v_period;
    case_name := 'a closed period refuses a backdated adjustment at the ledger, below the doors, and the raise that would post it leaves nothing behind';
    passed := coalesce(v_got like 'CLOVEERP_PERIOD_CLOSED%'
              and (select count(*) from erp.document d where d.tenant_id = r.tenant_id) = v_n, false);
    detail := left(v_got, 120);
    return next;

    -- ── 10. Tomorrow is refused ─────────────────────────────────────────────
    v_fixture := 'dating an adjustment in the future';
    begin
      perform erp.raise_stock_adjustment(v_site, 'DAMAGE_STORAGE',
                jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -1)),
                current_date + 1, 'Stock that will be missing tomorrow', 'ZZ-COUNT-5');
      v_got := 'it was accepted';
    exception when others then v_got := sqlerrm; end;
    case_name := 'an adjustment dated after today is refused: stock that will be missing next week is a forecast';
    passed := v_got like 'CLOVEERP_ADJUSTMENT_IN_THE_FUTURE%';
    detail := left(v_got, 90);
    return next;

    -- ── 11. A warehouse may adjust today and not last month ────────────────
    v_fixture := 'a principal who may adjust but may not post to the ledger';
    perform set_config('request.jwt.claims', json_build_object('sub', a_cnt)::text, true);
    begin
      v_got := erp.raise_stock_adjustment(v_site, 'DAMAGE_STORAGE',
                 jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -1, 'location_id', v_bulk)),
                 null, 'Dropped this morning', 'ZZ-COUNT-6') ->> 'state';
    exception when others then v_got := 'today was refused: ' || left(sqlerrm, 70); end;
    begin
      perform erp.raise_stock_adjustment(v_site, 'DAMAGE_STORAGE',
                jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -1, 'location_id', v_bulk)),
                current_date - 30, 'Dropped last month', 'ZZ-COUNT-7');
      v_got2 := 'last month was allowed too';
    exception when others then v_got2 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    case_name := 'somebody who may adjust stock and may not post to the ledger adjusts today, posted as it is raised, and cannot backdate: the control is the permission model, not a second one';
    passed := coalesce(v_got = 'posted' and v_got2 like 'CLOVEERP_PERMISSION_DENIED: finance.post%', false);
    detail := format('today %s; last month %s', v_got, left(v_got2, 70));
    return next;

    -- ── 12. COUNT_VARIANCE is the count's ───────────────────────────────────
    v_fixture := 'a count variance typed by hand';
    select count(*) into v_n from erp.document d where d.tenant_id = r.tenant_id;
    begin
      perform erp.raise_stock_adjustment(v_site, 'COUNT_VARIANCE',
                jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -40, 'location_id', v_bulk)),
                null, 'Counted short', null);
      v_got := 'went through';
    exception when others then v_got := sqlerrm; end;
    begin
      perform erp.raise_stock_adjustment(v_site, ' count_variance ', '[]'::jsonb, null, 'Counted short', null);
      v_got2 := 'went through';
    exception when others then v_got2 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a_cnt)::text, true);
    begin
      perform public.erp_raise_stock_adjustment(v_site, 'COUNT_VARIANCE',
                jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -40, 'location_id', v_bulk)),
                null, 'Counted short', null);
      v_got3 := 'went through';
    exception when others then v_got3 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    case_name := 'a COUNT_VARIANCE typed by hand is refused, in any case and through the public door, and leaves nothing behind: only a count writes one';
    passed := coalesce(v_got like 'CLOVEERP_COUNT_VARIANCE_IS_A_COUNTS%'
              and v_got2 like 'CLOVEERP_COUNT_VARIANCE_IS_A_COUNTS%'
              and v_got3 like 'CLOVEERP_COUNT_VARIANCE_IS_A_COUNTS%'
              and (select count(*) from erp.document d where d.tenant_id = r.tenant_id) = v_n, false);
    detail := format('by hand: %s; lower case: %s; the door: %s', left(v_got, 60), left(v_got2, 60), left(v_got3, 60));
    return next;

    -- ── 13. A write-off is a stock adjustment ───────────────────────────────
    v_fixture := 'a write-off';
    perform set_config('request.jwt.claims', json_build_object('sub', a_wo)::text, true);
    v_mv := public.erp_write_off_stock(v_item, v_site, v_bulk, 3, 'damaged in the aisle', null, null);
    begin
      perform erp.write_off_stock(v_item, v_site, v_bulk, 0, 'nothing at all');
      v_got := 'went through';
    exception when others then v_got := sqlerrm; end;
    begin
      perform erp.write_off_stock(v_item, v_site, v_bulk, -2, 'found two');
      v_got2 := 'went through';
    exception when others then v_got2 := sqlerrm; end;
    begin
      perform erp.raise_stock_adjustment(v_site, 'DAMAGE_STORAGE',
                jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -1, 'location_id', v_bulk)),
                null, 'dropped', null);
      v_got3 := 'went through';
    exception when others then v_got3 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select m.document_id into v_wo from erp.stock_movement m where m.id = v_mv;
    select string_agg(l.transition_code || coalesce('[' || (l.guard_data -> 'derived' ->> 'fact') || ']', ''), ',' order by l.id)
      into v_codes
      from erp.state_transition_log l where l.tenant_id = r.tenant_id and l.object_id = v_wo;
    case_name := 'a write-off is a stock adjustment under EXPIRY_WRITE_OFF, raised and posted by its door for somebody who may only write off, still a scrap at what the stock cost with their words on it; nothing or less is refused, and they may not raise an adjustment of their own';
    passed := coalesce(v_wo is not null
              and erp.document_state_code(v_wo) = 'posted'
              and v_codes = 'submit[erp.write_off_stock],approve_within_threshold[erp.approval_asked_nobody],post[erp.adjustment_is_approved]'
              and (select d.attributes ->> 'reason_code' from erp.document d where d.id = v_wo) = 'EXPIRY_WRITE_OFF'
              and exists (select 1 from erp.stock_movement m
                           where m.id = v_mv and m.movement_type = 'scrap' and m.quantity = 3
                             and m.reason_code = 'damaged in the aisle' and m.cost_minor = 1500
                             and m.from_location_id = v_bulk and m.document_line_id is not null)
              and v_got like 'CLOVEERP_WRITE_OFF_NEEDS_A_QUANTITY%'
              and v_got2 like 'CLOVEERP_WRITE_OFF_NEEDS_A_QUANTITY%'
              and v_got3 like 'CLOVEERP_PERMISSION_DENIED: inventory.adjust%', false);
    detail := format('movement %s on %s, which is %s; moves %s; nothing: %s; less: %s; an adjustment: %s',
                     v_mv, coalesce(v_wo::text, 'no document'), erp.document_state_code(v_wo), coalesce(v_codes, 'none'),
                     left(v_got, 50), left(v_got2, 50), left(v_got3, 50));
    return next;

    -- ── 14. The count's approve, and the post, are nobody's to press ────────
    v_fixture := 'a draft filled by hand';
    v_empty := (erp.raise_stock_adjustment(v_site, 'DAMAGE_STORAGE', '[]'::jsonb, null, 'dropped', null) ->> 'document_id')::uuid;
    v_got4 := erp.document_state_code(v_empty);
    perform erp.add_document_line(v_empty, v_item, -1, 0, null, null);
    v_got  := erp_test.stock_state_try(v_empty, 'approve_with_count');
    v_got2 := erp_test.stock_state_try(v_empty, 'post');
    v_got3 := erp_test.stock_state_try(v_empty, 'approve_within_threshold');
    select count(*) into v_n
      from jsonb_array_elements(public.erp_available_transitions(v_empty)) x
     where x ->> 'code' in ('approve_with_count', 'post', 'approve_within_threshold')
       and (x ->> 'permitted')::boolean and coalesce((x ->> 'guard_passes')::boolean, true);
    v_got5 := public.erp_transition_document(v_empty, 'submit', 'filled in') ->> 'state';
    case_name := 'a draft raised empty and filled by hand is not approved with a count it is not, nor posted, nor approved within a threshold by a press; submitted, it is approved and posted';
    passed := coalesce(v_got4 = 'draft'
              and v_got like 'CLOVEERP_ADJUSTMENT_APPROVED_WITH_ITS_COUNT%'
              and v_got2 like 'CLOVEERP_TRANSITION_NOT_PERMITTED%'
              and v_got3 like 'CLOVEERP_TRANSITION_NOT_PERMITTED%'
              and v_got5 = 'posted', false);
    detail := format('raised %s; with a count: %s; post: %s; within the threshold: %s; %s offered; submitted to %s',
                     v_got4, left(v_got, 60), left(v_got2, 50), left(v_got3, 50), v_n, v_got5);
    return next;

    -- ── 15. With a threshold set, a large adjustment waits for somebody else
    v_fixture := 'a threshold';
    res := public.erp_propose_approval_chain('stock_adjustment_value', 'Stock adjustment value approval', 'document',
      jsonb_build_array(jsonb_build_object('seq', 1, 'code', 'stock_controller', 'name', 'Stock controller',
        'role', 'inventory', 'min_approvals', 1,
        'condition', jsonb_build_object('>', jsonb_build_array(jsonb_build_object('var', 'value_at_cost_minor'), 1000)))),
      jsonb_build_object('==', jsonb_build_array(jsonb_build_object('var', 'document_type'), 'stock_adjustment')),
      'value_at_cost_minor', 100, 'a threshold of ten pounds at cost');
    v_ok := (res ->> 'in_force')::boolean;
    update erp.environment set is_live = true where tenant_id = r.tenant_id and is_self;
    perform set_config('request.jwt.claims', json_build_object('sub', a_mov)::text, true);
    v_small := (erp.raise_stock_adjustment(v_site, 'DAMAGE_STORAGE',
                  jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -1, 'location_id', v_bulk)),
                  null, 'one dropped', null) ->> 'document_id')::uuid;
    v_big := (erp.raise_stock_adjustment(v_site, 'DAMAGE_STORAGE',
                jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -5, 'location_id', v_bulk)),
                null, 'a pallet went over', null) ->> 'document_id')::uuid;
    v_got  := erp.document_state_code(v_big);
    v_got2 := erp_test.stock_state_try(v_big, 'approve_within_threshold');
    v_got3 := erp_test.stock_state_try(v_big, 'approve');
    begin
      perform erp.post_stock_adjustment(v_big);
      v_got4 := 'went through';
    exception when others then v_got4 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a_app)::text, true);
    v_got5 := public.erp_transition_document(v_big, 'approve', 'fine by me') ->> 'state';
    select count(*) into v_n
      from erp.approval_task t join erp.approval_request q on q.id = t.approval_request_id
     where q.tenant_id = r.tenant_id and q.object_id = v_big and t.status <> 'skipped' and t.assignee_user_id = v_mov;
    select l.guard_data -> 'derived' ->> 'fact' into v_got6
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_id = v_big and l.transition_code = 'post';
    perform set_config('request.jwt.claims', json_build_object('sub', a_mov)::text, true);
    case_name := 'with a threshold set, an adjustment under it posts as it is raised and one over it waits: its raiser may not approve it within the threshold or at all, nor confirm it, and somebody else''s approve posts it';
    passed := coalesce(v_ok and erp.document_state_code(v_small) = 'posted'
              and v_got = 'pending_approval'
              and v_got2 like 'CLOVEERP_ADJUSTMENT_AWAITS_APPROVAL%'
              and (v_got3 like 'CLOVEERP_DOCUMENT_APPROVAL_PENDING%' or v_got3 like 'CLOVEERP_DOCUMENT_SELF_APPROVAL%')
              and v_got4 like 'CLOVEERP_ADJUSTMENT_NOT_APPROVED%'
              and v_got5 = 'posted' and v_n = 0 and v_got6 = 'erp.adjustment_is_approved'
              and (select coalesce(sum(m.quantity), 0) from erp.stock_movement m
                    where m.tenant_id = r.tenant_id and m.document_id = v_big) = 5, false);
    detail := format('proposed %s; over the threshold %s; within the threshold: %s; the raiser''s approve: %s; confirmed: %s; the approver: %s, post derived from %s',
                     v_ok, v_got, left(v_got2, 50), left(v_got3, 60), left(v_got4, 50), v_got5, coalesce(v_got6, 'nothing'));
    return next;

    -- ── 16. Waiting, it is not changed ──────────────────────────────────────
    v_fixture := 'lines while waiting';
    v_rt := (erp.raise_stock_adjustment(v_site, 'DAMAGE_STORAGE',
               jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -5, 'location_id', v_bulk)),
               null, 'a pallet went over', null) ->> 'document_id')::uuid;
    begin
      perform erp.add_document_line(v_rt, v_item, -900, 0, null, null);
      v_got := 'went through';
    exception when others then v_got := sqlerrm; end;
    select l.id into v_line from erp.document_line l where l.tenant_id = r.tenant_id and l.document_id = v_rt;
    begin
      perform erp.set_line_stock_identity(v_line, null, v_bulk, null);
      v_got2 := 'went through';
    exception when others then v_got2 := sqlerrm; end;
    begin
      perform erp.amend_document_line(v_line, -50, 'made bigger while it waits');
      v_got3 := 'went through';
    exception when others then v_got3 := sqlerrm; end;
    case_name := 'an adjustment waiting for approval takes no new line, no stock pinned to its lines and no amendment, so what is approved is what was asked about';
    passed := coalesce(erp.document_state_code(v_rt) = 'pending_approval'
              and v_got like 'CLOVEERP_ADJUSTMENT_CHANGED_ONLY_AS_A_DRAFT%'
              and v_got2 like 'CLOVEERP_ADJUSTMENT_CHANGED_ONLY_AS_A_DRAFT%'
              and v_got3 like 'CLOVEERP_PAST_AMENDMENT_CUT_OFF: adjustment_submitted%'
              and (select sum(l.quantity) from erp.document_line l where l.document_id = v_rt) = -5, false);
    detail := format('a new line: %s; stock pinned: %s; amended: %s', left(v_got, 70), left(v_got2, 70), left(v_got3, 70));
    return next;

    -- ── 16b. A rejection is the approver's, or the raiser's withdrawal ──────
    -- (found by the PR11 M6 walk): v_rt waits, raised by the mover.
    v_fixture := 'who rejects';
    perform set_config('request.jwt.claims', json_build_object('sub', a_cnt)::text, true);
    v_got  := erp_test.stock_state_try(v_rt, 'reject');
    select x ->> 'refused' into v_got4
      from jsonb_array_elements(public.erp_available_transitions(v_rt)) x where x ->> 'code' = 'reject';
    perform set_config('request.jwt.claims', json_build_object('sub', a_app)::text, true);
    v_got2 := erp_test.stock_state_try(v_rt, 'reject');
    select coalesce(x ->> 'refused', 'none') into v_got5
      from jsonb_array_elements(public.erp_available_transitions(v_rt)) x where x ->> 'code' = 'reject';
    perform set_config('request.jwt.claims', json_build_object('sub', a_mov)::text, true);
    v_got3 := public.erp_transition_document(v_rt, 'reject', 'raised by mistake') ->> 'state';
    case_name := 'an adjustment waiting for approval is rejected by the approver it asked and withdrawn by its raiser, and somebody else who may adjust stock is refused and offered nothing';
    passed := coalesce(v_got like 'CLOVEERP_REJECT_IS_THE_APPROVERS%'
              and v_got4 = 'CLOVEERP_REJECT_IS_THE_APPROVERS'
              and v_got2 = 'went through' and v_got5 = 'none'
              and v_got3 = 'draft'
              and not exists (select 1 from erp.stock_movement m where m.tenant_id = r.tenant_id and m.document_id = v_rt), false);
    detail := format('the adjuster asked nothing: %s, offered as %s; the approver: %s, refused %s; the raiser withdrew it to %s',
                     left(v_got, 60), coalesce(v_got4, 'nothing'), v_got2, v_got5, v_got3);
    return next;

    -- ── 17. A reason that requires approval asks once a threshold is set ────
    v_fixture := 'a reason that requires approval, under the threshold';
    v_theft := (erp.raise_stock_adjustment(v_site, 'THEFT_LOSS',
                  jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -1, 'location_id', v_bulk)),
                  null, 'One walked out of the loading bay', null) ->> 'document_id')::uuid;
    select q.value_at_approval into v_q
      from erp.approval_request q where q.tenant_id = r.tenant_id and q.object_id = v_theft;
    case_name := 'once a threshold is set, a reason the register says requires approval is asked about whatever it is worth: one unit of theft waits for somebody else';
    passed := coalesce(erp.document_state_code(v_theft) = 'pending_approval' and v_q = 9223372036854775807, false);
    detail := format('%s, valued %s', erp.document_state_code(v_theft), coalesce(v_q::text, 'nothing'));
    return next;

    -- ── 18. A write-off over the threshold waits too ────────────────────────
    v_fixture := 'a write-off over the threshold';
    perform set_config('request.jwt.claims', json_build_object('sub', a_wo)::text, true);
    v_mv  := erp.write_off_stock(v_item, v_site, v_bulk, 1, 'one scuffed');
    v_mv2 := erp.write_off_stock(v_item, v_site, v_bulk, 5, 'a box crushed');
    perform set_config('request.jwt.claims', json_build_object('sub', a_app)::text, true);
    select d.id into v_wo_big
      from erp.document d
     where d.tenant_id = r.tenant_id and d.attributes ->> 'reason_note' = 'a box crushed';
    v_got := erp.document_state_code(v_wo_big);
    select t.id into v_task
      from erp.approval_task t join erp.approval_request q on q.id = t.approval_request_id
     where q.tenant_id = r.tenant_id and q.object_id = v_wo_big and t.status = 'pending'
       and t.assignee_user_id = v_app limit 1;
    perform erp.decide_approval_task(v_task, true, 'the box was crushed');
    perform set_config('request.jwt.claims', json_build_object('sub', a_mov)::text, true);
    case_name := 'a write-off is not a way round the threshold: under it, it posts and returns its movement; over it, it returns none and waits, and posts when somebody else approves it';
    passed := coalesce(v_mv is not null and v_mv2 is null
              and v_got = 'pending_approval'
              and erp.document_state_code(v_wo_big) = 'posted'
              and exists (select 1 from erp.stock_movement m
                           where m.tenant_id = r.tenant_id and m.document_id = v_wo_big
                             and m.movement_type = 'scrap' and m.quantity = 5 and m.reason_code = 'a box crushed'), false);
    detail := format('under it: movement %s; over it: movement %s, %s, then %s', coalesce(v_mv::text, 'none'),
                     coalesce(v_mv2::text, 'none'), coalesce(v_got, 'no adjustment'), erp.document_state_code(v_wo_big));
    return next;

    -- ── 19. Decided under My approvals, it moves with the decision ─────────
    v_fixture := 'My approvals';
    v_mya := (erp.raise_stock_adjustment(v_site, 'DAMAGE_STORAGE',
                jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -5, 'location_id', v_bulk)),
                null, 'a pallet went over', null) ->> 'document_id')::uuid;
    v_myr := (erp.raise_stock_adjustment(v_site, 'DAMAGE_STORAGE',
                jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -6, 'location_id', v_bulk)),
                null, 'two pallets went over', null) ->> 'document_id')::uuid;
    perform set_config('request.jwt.claims', json_build_object('sub', a_app)::text, true);
    select t.id into v_task
      from erp.approval_task t join erp.approval_request q on q.id = t.approval_request_id
     where q.tenant_id = r.tenant_id and q.object_id = v_mya and t.status = 'pending' and t.assignee_user_id = v_app limit 1;
    perform erp.decide_approval_task(v_task, true, 'fine by me');
    select t.id into v_task
      from erp.approval_task t join erp.approval_request q on q.id = t.approval_request_id
     where q.tenant_id = r.tenant_id and q.object_id = v_myr and t.status = 'pending' and t.assignee_user_id = v_app limit 1;
    perform erp.decide_approval_task(v_task, false, 'count them again');
    perform set_config('request.jwt.claims', json_build_object('sub', a_mov)::text, true);
    select string_agg(l.transition_code || coalesce('[' || (l.guard_data -> 'derived' ->> 'fact') || ']', ''), ',' order by l.id)
      into v_codes from erp.state_transition_log l where l.tenant_id = r.tenant_id and l.object_id = v_mya;
    select l.id into v_line from erp.document_line l where l.tenant_id = r.tenant_id and l.document_id = v_myr;
    v_got2 := erp.document_state_code(v_myr);
    perform erp.amend_document_line(v_line, -1, 'only one after all');
    v_got3 := public.erp_transition_document(v_myr, 'submit', 'smaller now') ->> 'state';
    case_name := 'an adjustment approved under My approvals is posted, and one rejected there goes back to draft, is changed there, and submitted again under the threshold is posted';
    passed := coalesce(erp.document_state_code(v_mya) = 'posted'
              and v_codes = 'submit,approve[erp.approval_request],post[erp.adjustment_is_approved]'
              and v_got2 = 'draft' and v_got3 = 'posted', false);
    detail := format('approved one %s by %s; rejected one %s, then %s', erp.document_state_code(v_mya), coalesce(v_codes, 'nothing'),
                     v_got2, v_got3);
    return next;

    -- ── 20. Not approved over lines changed since it was asked ──────────────
    v_fixture := 'a line changed behind the doors';
    v_edit := (erp.raise_stock_adjustment(v_site, 'DAMAGE_STORAGE',
                 jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -5, 'location_id', v_bulk)),
                 null, 'a pallet went over', null) ->> 'document_id')::uuid;
    update erp.document_line set quantity = -60 where tenant_id = r.tenant_id and document_id = v_edit;
    perform set_config('request.jwt.claims', json_build_object('sub', a_app)::text, true);
    v_got := erp_test.stock_state_try(v_edit, 'approve');
    perform set_config('request.jwt.claims', json_build_object('sub', a_mov)::text, true);
    case_name := 'an adjustment whose lines changed after its approval was asked for is not approved, and nothing is written off';
    passed := coalesce(v_got like 'CLOVEERP_DOCUMENT_CHANGED_SINCE_APPROVAL%'
              and erp.document_state_code(v_edit) = 'pending_approval'
              and not exists (select 1 from erp.stock_movement m where m.tenant_id = r.tenant_id and m.document_id = v_edit), false);
    detail := format('%s; stands %s', left(v_got, 90), erp.document_state_code(v_edit));
    return next;

    -- ── 21. The ties hold with all of it in the books ───────────────────────
    v_fixture := 'reading the ties';
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select coalesce(sum(v.value_minor), 0)::bigint into v_val from erp.stock_valuation_report() v;
    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)::bigint into v_ledger
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = r.tenant_id and j.status = 'posted' and a.code = erp.tenant_account_code('inventory');
    begin
      v_got := erp.assert_trial_balance_balances() || '; ' || erp.assert_stock_reconciles();
      v_ok := true;
    exception when others then v_ok := false; v_got := left(sqlerrm, 200); end;
    case_name := 'the trial balance balances and the stock ledger reconciles with every route in the books: raised, backdated, found, layered, written off, approved and confirmed';
    passed := v_ok;
    detail := format('%s; valuation %s against inventory %s', v_got, v_val, v_ledger);
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(v_fixture || ': ' || sqlerrm, 300);
      return next;
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-sas-' || v_hex)
            and current_user = v_owner
            and coalesce(current_setting('erp.deriving_move', true), '') = '';
  detail := 'the organisation, its adjustments, write-offs, chain and postings rolled back, and no move named';
  return next;
end;
$$;

revoke all on function erp_test.stock_adjustment_suite() from public, anon;

comment on function erp_test.stock_adjustment_suite() is
  'Version 2 of the stock adjustment''s lifecycle (20260928500000): installed and taken as an upgrade, '
  'version 1 in flight, posted as it is raised with no threshold, dated, costed, found, layered and '
  'refused a closed period, tomorrow and a backdate without finance.post; COUNT_VARIANCE refused; the '
  'write-off an adjustment; the count''s approve nobody''s to press; the threshold, the reason that '
  'requires approval, My approvals, no change while waiting, and the ties.';

create or replace function erp_test.assert_stock_adjustment_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
  v_ended  text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false)),
         max(s.detail) filter (where s.case_name = 'the suite ran to its end')
    into v_failed, v_total, v_detail, v_ended
    from erp_test.stock_adjustment_suite() s;
  -- Failures first, so a suite that stopped part way says where.
  if v_failed > 0 then
    raise exception 'CLOVEERP_STOCK_ADJUSTMENT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A stock adjustment was approved, posted or refused other than its lifecycle says. Read the case that failed.';
  end if;
  if v_total <> 23 then
    raise exception 'CLOVEERP_STOCK_ADJUSTMENT_SUITE_SHRANK: % case(s), expected 23; the fixture stopped %', v_total,
      coalesce(v_ended, 'nowhere')
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('stock adjustments: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_stock_adjustment_suite() from public, anon;

comment on function erp_test.assert_stock_adjustment_suite() is
  'Version 2 of the stock adjustment''s lifecycle is approved by its value, posts on approval, refuses a '
  'hand-typed COUNT_VARIANCE and takes the write-off through it, and version 1 in flight moves as it did '
  '(20260928500000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- F1. The count suites: a count whose post was refused is put back
-- ─────────────────────────────────────────────────────────────────────────────

do $cap$
declare
  v_sig constant text := 'erp_test.count_autopost_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    return query select 'each count posted as it was recorded was posted by the system, and each posted by hand by its poster',
      v_n = 10 and v_n2 = 5,
      format('%s derived post(s), %s by hand', v_n, v_n2);
$o$;
  v_new constant text := $n$    return query select 'each count posted as it was recorded was posted by the system, and each posted by hand by its poster',
      v_n = 10 and v_n2 = 5,
      format('%s derived post(s), %s by hand', v_n, v_n2);

    -- 20. The count whose post was refused for good (case 11) is put back
    --     (20260928500000, M5, D14): cancelled with a reason by somebody who
    --     may adjust stock, its place released, nothing posted, and its sheet
    --     closes with the last of its counts.
    v_fixture := 'cancelling N, whose post was refused';
    v_err := null; v_status := null;
    select t.document_id into v_doc from erp.count_task t where t.id = t_n;
    begin
      perform public.erp_cancel_count_task(t_n, '  ');
    exception when others then v_err := sqlerrm; end;
    -- The two counts the suite left open on its sheet, R and T, withdrawn
    -- first, so the sheet has only this one left to wait for.
    perform public.erp_cancel_count_task(t.id, 'Not counted this round')
       from erp.count_task t
      where t.tenant_id = r.tenant_id and t.document_id = v_doc and t.id <> t_n and t.status = 'open';
    select count(*), string_agg(i.code || ' ' || t.status::text || coalesce(' ' || left(t.post_held_reason, 20), ''), ', ')
      into v_n3, v_detail
      from erp.count_task t join erp.item i on i.id = t.item_id
     where t.tenant_id = r.tenant_id and t.document_id = v_doc and t.id <> t_n
       and t.status not in ('posted', 'cancelled');
    v_status := public.erp_cancel_count_task(t_n, 'The bay it counted was taken off the layout')::text;
    select count(*) into v_locks from erp.count_lock l
     where l.tenant_id = r.tenant_id and l.count_task_id = t_n and l.released_at is null;
    select string_agg(l.transition_code, ',' order by l.occurred_at, l.id) into v_log
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'count_task' and l.object_id = t_n
       and l.transition_code is not null;
    return query select 'a count whose post was refused is cancelled with a reason, its place released and nothing posted, and its sheet closes with it',
      coalesce(v_err like 'CLOVEERP_COUNT_CANCELLATION_NEEDS_A_REASON%'
      and v_status = 'cancelled' and v_locks = 0
      and v_log = 'record_approved,cancel_approved'
      and (select t.adjustment_document_id is null and t.posted_at is null from erp.count_task t where t.id = t_n)
      and v_n3 = 0 and erp.document_state_code(v_doc) = 'closed', false),
      format('without a reason: %s; cancelled %s; %s live lock(s); history %s; %s other count(s) open on its sheet (%s), which is %s',
             left(coalesce(v_err, 'accepted'), 60), coalesce(v_status, 'not'), v_locks, v_log, v_n3, coalesce(v_detail, 'none'),
             coalesce(erp.document_state_code(v_doc), 'on no sheet'));
$n$;
  n integer;
begin
  if position('cancelling N, whose post was refused' in v_def) > 0 then
    raise notice '% already puts a refused count back; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % last case anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$cap$;

do $cap_approve$
declare
  v_sig constant text := 'erp_test.count_autopost_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$       and l.object_id = (select t.adjustment_document_id from erp.count_task t where t.id = t_b)
       and l.transition_code = 'approve';
$o$;
  v_new constant text := $n$       and l.object_id = (select t.adjustment_document_id from erp.count_task t where t.id = t_b)
       -- approve_with_count since 20260928500000 (D9).
       and l.transition_code = 'approve_with_count';
$n$;
  n integer;
begin
  if position('approve_with_count since 20260928500000' in v_def) > 0 then
    raise notice '% already reads approve_with_count; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % approve anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$cap_approve$;

do $cap_assert$
declare
  v_sig constant text := 'erp_test.assert_count_autopost_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  if v_total <> 23 then
    raise exception 'CLOVEERP_COUNT_AUTOPOST_SUITE_SHRANK: % case(s), expected 23; the fixture stopped %', v_total,$o$;
  v_new constant text := $n$  -- 24 since 20260928500000: a count whose post was refused is put back.
  if v_total <> 24 then
    raise exception 'CLOVEERP_COUNT_AUTOPOST_SUITE_SHRANK: % case(s), expected 24; the fixture stopped %', v_total,$n$;
  n integer;
begin
  if position('24 since 20260928500000' in v_def) > 0 then
    raise notice '% already expects 24; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % count anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$cap_assert$;

do $cwl$
declare
  v_sig constant text := 'erp_test.count_worklist_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$      format('ours %s row(s), theirs %s; the counter''s read and the owner''s agree %s',
             jsonb_array_length(v_rows), jsonb_array_length(v_rows_o), v_rows = v_rows_owner);
$o$;
  v_new constant text := $n$      format('ours %s row(s), theirs %s; the counter''s read and the owner''s agree %s',
             jsonb_array_length(v_rows), jsonb_array_length(v_rows_o), v_rows = v_rows_owner);

    -- 13. An approved count is put back only once its post was refused
    --     (20260928500000, M5, D14). H is held by the site's policy, and P
    --     posted: neither is cancelled. H's post then refused, it is, reads
    --     cancelled with nothing to wait for, and the sheet it shared with P
    --     closes.
    v_fixture := 'putting back a count whose post was refused';
    begin
      perform public.erp_cancel_count_task(t_h, 'Held, and nobody wants to post it');
      v_status := 'went through';
    exception when others then v_status := sqlerrm; end;
    begin
      perform public.erp_cancel_count_task(t_p, 'Posted already');
      v_status2 := 'went through';
    exception when others then v_status2 := sqlerrm; end;
    update erp.count_task
       set post_held_reason = 'post_refused: 23502 CLOVEERP_COUNT_HAS_NO_PLACE: planted by the suite'
     where id = t_h;
    v_status3 := public.erp_cancel_count_task(t_h, 'The bay it counted was taken off the layout')::text;
    select x into x_h from jsonb_array_elements(public.erp_count_tasks(500)) x where x ->> 'task_id' = t_h::text;
    return query select 'an approved count is cancelled only once its post was refused: held by the policy, or posted, it is not; refused, it is, reads cancelled with nothing to wait for, and its sheet closes',
      coalesce(v_status like 'CLOVEERP_COUNT_TASK_NOT_CANCELLABLE%'
      and v_status2 like 'CLOVEERP_COUNT_TASK_NOT_CANCELLABLE%'
      and v_status3 = 'cancelled'
      and x_h ->> 'status' = 'cancelled' and x_h -> 'post_held_reason' = 'null'::jsonb
      and x_h -> 'adjustment_document_id' = 'null'::jsonb
      and not exists (select 1 from erp.count_lock l
                       where l.tenant_id = r.tenant_id and l.count_task_id = t_h and l.released_at is null)
      and erp.document_state_code(v_hold) = 'closed', false),
      format('held: %s; posted: %s; refused: %s; reads %s; its sheet %s',
             left(v_status, 60), left(v_status2, 60), coalesce(v_status3, 'not cancelled'),
             coalesce(x_h ->> 'status', 'not listed'), erp.document_state_code(v_hold));
$n$;
  n integer;
begin
  if position('putting back a count whose post was refused' in v_def) > 0 then
    raise notice '% already puts a refused count back; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % last case anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$cwl$;

do $cwl_assert$
declare
  v_sig constant text := 'erp_test.assert_count_worklist_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  if v_total <> 13 then
    raise exception 'CLOVEERP_COUNT_WORKLIST_SUITE_SHRANK: % case(s), expected 13; the fixture stopped %', v_total,$o$;
  v_new constant text := $n$  -- 14 since 20260928500000: a count whose post was refused is put back.
  if v_total <> 14 then
    raise exception 'CLOVEERP_COUNT_WORKLIST_SUITE_SHRANK: % case(s), expected 14; the fixture stopped %', v_total,$n$;
  n integer;
begin
  if position('14 since 20260928500000' in v_def) > 0 then
    raise notice '% already expects 14; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % count anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$cwl_assert$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F2. The words the Stock adjustments screen says for it
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). The Stock adjustments screen, on version 2 of the stock adjustment''s lifecycle (20260928500000).'
  from (values
    ('An adjustment carries the date the count was taken and the reason it changed, and over the organisation''s threshold it waits for an approval before anything is written. Its cost is counted on the day the count was taken, not the day it was typed in.'),
    ('An adjustment is posted as it is raised unless it is worth more than the organisation''s threshold, or gives a reason set up to need approval once a threshold is set: then it waits for somebody else to approve it, and is posted as they do. Dating one before today needs the permission to post to the ledger as well, and a closed period refuses it outright.'),
    ('Posted as it is raised, unless it is worth more than the organisation''s threshold: then it waits for somebody else to approve it. Quantities are what you found, not what you want to change by — put stock found as a positive number and stock missing as a negative one.')
  ) as v(text)
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
