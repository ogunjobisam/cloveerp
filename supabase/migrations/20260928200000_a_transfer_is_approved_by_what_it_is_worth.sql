set lock_timeout = '30s';

-- =============================================================================
-- 20260928200000  A transfer is approved by what it is worth
-- -----------------------------------------------------------------------------
-- PR11, M3 (docs/spec/simplification-review.md §7, nodes I5 for the transfer
-- order, I7, and the half of C3 that 20260922200000 and 20260928000000 left):
-- version 2 of the transfer order's lifecycle, delivered to an organisation
-- already live as version 8 of inventory-operations through the upgrade
-- register, to a demonstration through its catch-up, and to a new organisation
-- at install. Decisions D4 to D8 as taken on 25 September, and the receiving
-- site's close as taken on 26 September.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- On a database built from main (PR11 scoping, E1 and E3):
--
--   * A transfer was approved by one click on inventory.move, by the person
--     who raised it, whatever it was worth. Nothing could hold a large one for
--     somebody else: a chain named on the type was never asked, because the
--     move was coded `approved` where the engine acts on `approve`, nothing
--     requested an approval, and the value the engine reads was nought,
--     because a transfer's lines carry no price.
--   * 13 of the lifecycle's 16 transitions declared no permission. PR11 M1
--     (20260928000000) asks the type's own permission of them in code; this
--     writes it into the lifecycle.
--   * Discrepancy, and its six moves, were a state nothing but a click
--     reached, and M1 refuses every way in. The cancellations out of issued,
--     in transit and received could never be taken once stock had moved.
--   * Closed had no caller: every transfer the demonstration builds stops at
--     received.
--   * An approved transfer could be amended to any quantity and kept its
--     approval.
--   * The base pack shipped a second copy of the lifecycle with no
--     permission on any move.
--
-- ── WHAT VERSION 2 OF THE TRANSFER ORDER'S LIFECYCLE IS ──────────────────────
--
--   draft            → pending_approval  submit (asks for the approval)
--   pending_approval → approved          approve, by somebody the chain asked
--   pending_approval → draft             reject
--   pending_approval → approved          approve_within_threshold: derived, when
--                                        the approval asked nobody
--   approved         → issued            issued: derived, as the despatch
--                                        loads it; refused by hand
--   issued           → in_transit        in_transit    the despatch door's
--   in_transit       → received          received      the receive door's
--   received         → closed            close: derived, once everything
--                                        despatched has arrived
--   draft            → cancelled         cancel
--   approved         → cancelled         cancel_approved (M1 refuses it once
--                                        stock has moved)
--
-- Every move asks inventory.move. No discrepancy, and no cancellation once
-- the goods are loaded.
--
--   * The chain, transfer_order_value, reads value_at_cost_minor: every line's
--     quantity at the despatching site's unit cost, which
--     erp.document_transition_context() now carries for a transfer order and
--     a stock adjustment. Its one step asks the inventory role (D4b), and its
--     condition is `false`: no transfer needs anybody's approval until the
--     organisation sets its threshold, by proposing the chain again with the
--     step's condition {">": [{"var": "value_at_cost_minor"}, <minor units>]}
--     on the Configuration screen (D4, D5). The threshold lives in one place,
--     as the quote's discount threshold does.
--   * Raising submits. When the approval asked nobody, the order is approved
--     at once by approve_within_threshold, derived from the fact
--     erp.approval_asked_nobody(); today's same-person click is gone (D5).
--     Otherwise it waits in pending_approval for the people the chain asked,
--     and the one who raised it is refused, by the engine, in a live
--     organisation.
--   * Receiving takes received, then close, derived from
--     erp.transfer_is_received_in_full(). A close asked for by hand goes the
--     same way, through erp.close_transfer_when_received(), which asks
--     inventory.move at the RECEIVING site only: the receiving site may close
--     a transfer on its own; despatch and receive still ask both sites.
--   * An approved transfer, or one waiting for approval, is not amended (D6):
--     erp.amendment_allowed() says transfer_approved, and it takes no new line
--     and no stock pinned to a line (CLOVEERP_TRANSFER_CHANGED_ONLY_AS_A_
--     DRAFT). And a transfer order or stock adjustment whose lines or chain's
--     material fields have changed since its approval was asked for is not
--     approved over them (CLOVEERP_DOCUMENT_CHANGED_SINCE_APPROVAL). Asked of
--     every document type, it refused a requisition corrected while it
--     waited, which is a decision of its own.
--   * Decided under My approvals, a transfer moves with the decision:
--     erp.settle_approval_outcome() takes approve or reject, derived from the
--     request, as it does for a count task.
--   * A request still pending asks somebody, whatever the type names now.
--   * A line whose stock has no cost at the despatching site is worth more
--     than any threshold clears, so a threshold, once set, asks about it.
--   * The driver register keeps version 1's retired rows only while a version
--     in use declares them (erp.transition_in_use(): in force, or with a
--     document on it), and the undriven report reads such a row as the
--     register speaking for documents in flight, not as drift. An
--     organisation with none reads as version 2 alone.
--
-- ── WHAT CHANGES FOR DOCUMENTS IN FLIGHT ─────────────────────────────────────
--
-- Nothing moves on its own. A transfer stays on the version it started on;
-- version 1's moves stay as they were, M1's refusals and its fallback
-- permission still govern them, and a received version 1 transfer is not
-- swept to closed (D7). Two things reach them: an approved transfer is not
-- amended, on any version; and issued, in transit and received are the
-- doors' moves on the screen for either version, as they always were in the
-- database.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * The stock adjustment's lifecycle is M4's (inventory-operations v9). The
--     context's value_at_cost_minor is read for it already, and read by
--     nothing yet.
--   * No Approve or Reject on the transfers screen: that is M6. The document
--     page draws both, as it does for every lifecycle with a chain.
--   * The receiving site's close is not offered as a button: a version 2
--     transfer received in full closes in the same press, so it never rests in
--     received. The database takes the close from the receiving site alone
--     whenever something asks for it.
--   * No public function, so no allowance and no door.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The refusal this adds
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_TRANSFER_AWAITS_APPROVAL',
  'Approving a transfer order within its threshold while somebody has been asked to approve it.',
  'A transfer is approved within its threshold only when its value asked nobody. Once somebody has been asked, the transfer waits for their decision, so a large transfer cannot be waved through by the person who raised it.',
  'Ask the people named under My approvals to decide it. The transfer is approved, or sent back to draft, as they decide.');

select erp.register_refusal('CLOVEERP_TRANSFER_CHANGED_ONLY_AS_A_DRAFT',
  'Adding a line to a transfer order, or pinning stock to one of its lines, once it has been submitted.',
  'A transfer is approved for what it says when it is submitted. A line added while it waits, or after, would be loaded and moved with an approval given for less.',
  'Have the transfer rejected back to draft, change it there and submit it again, or raise a second transfer for what is left.');

select erp.register_refusal('CLOVEERP_DOCUMENT_CHANGED_SINCE_APPROVAL',
  'Approving a document whose lines or terms have changed since its approval was asked for.',
  'The approval was asked for what the document said when it was submitted. Approving it now would approve something nobody was asked about.',
  'Send it back to draft and submit it again, so that the approval is asked for what it now says.');

select erp.register_refusal('CLOVEERP_TRANSFER_LOADED_BY_ITS_DOOR',
  'Marking a transfer order issued by hand.',
  'Issued means the goods are being loaded. Marked by hand, the transfer would stand issued with nothing loaded and no way back, because it can then neither be cancelled nor sent on without stock.',
  'Despatch it from the Site transfers screen, which loads the goods and marks it issued and in transit in the same press.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. What a transfer is worth, whether anybody was asked, and whether it
--     has all arrived
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.document_value_at_cost_minor(p_document_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  -- What a document's lines are worth at what their stock costs where the
  -- document stands (20260928200000): each line's quantity, taken as it is
  -- whichever way it moves, at the document's site's unit cost. A transfer
  -- order's and a stock adjustment's lines carry no price, so this is the
  -- value an approval threshold on either reads. A line whose stock has no
  -- cost at the site is worth more than any threshold can clear, so a
  -- threshold, once set, always asks about it; with none set nobody is asked.
  select case when bool_or(x.cost is null) then 9223372036854775807
              else coalesce(sum(round(abs(x.quantity) * x.cost)), 0)::bigint end
    from (select l.quantity, erp.unit_cost_at(l.item_id, d.site_id) as cost
            from erp.document d
            join erp.document_line l on l.tenant_id = d.tenant_id and l.document_id = d.id
           where d.tenant_id = erp.current_tenant_id()
             and d.id = p_document_id
             and not l.is_cancelled
             and l.item_id is not null) x
$$;

revoke all on function erp.document_value_at_cost_minor(uuid) from public, anon;

comment on function erp.document_value_at_cost_minor(uuid) is
  'A document''s lines at the unit cost of their stock at the document''s site, each quantity taken '
  'whichever way it moves, and the largest value there is when a line''s stock has no cost there: the '
  'value_at_cost_minor an approval chain on a transfer order or a stock adjustment reads (20260928200000).';

create or replace function erp.transfer_is_past_draft(p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- A transfer order submitted and not yet finished (20260928200000): waiting
  -- for approval, approved, or on its way. What was approved is what moves,
  -- so its lines are not changed: read by erp.amendment_allowed(),
  -- erp.add_document_line() and erp.set_line_stock_identity().
  select exists (
    select 1
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      join erp.object_state os
        on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      join erp.state s on s.id = os.current_state_id
     where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id
       and dt.base_type_code = 'transfer_order'
       and not d.is_cancelled
       and not s.is_initial and not s.is_terminal)
$$;

revoke all on function erp.transfer_is_past_draft(uuid) from public, anon;

comment on function erp.transfer_is_past_draft(uuid) is
  'True for a transfer order submitted and not yet finished, whose lines are no longer changed (20260928200000).';

create or replace function erp.document_changed_since_request(p_request_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- Whether a transfer order or a stock adjustment says something other than
  -- it said when the approval request was made (20260928200000): its lines, by the fingerprint the
  -- request recorded, or the material fields its chain names, by the digest
  -- the request recorded. The value field is left to its own tolerance, as
  -- erp.material_fingerprint() leaves it. Read by
  -- erp.require_document_approval() before an approval is taken.
  select coalesce(
           (q.context ? 'line_fingerprint'
            and q.context ->> 'line_fingerprint' is distinct from erp.document_line_fingerprint(q.object_id))
        or (cardinality(cv.material_fields) > 0
            and q.material_fingerprint is distinct from erp.material_fingerprint(
                  erp.document_transition_context(q.object_id, 'approve')
                    || jsonb_build_object('line_fingerprint', erp.document_line_fingerprint(q.object_id)),
                  cv.material_fields, cv.value_field)), false)
    from erp.approval_request q
    join erp.approval_chain_version cv on cv.tenant_id = q.tenant_id and cv.id = q.approval_chain_version_id
    join erp.document d on d.tenant_id = q.tenant_id and d.id = q.object_id
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where q.tenant_id = erp.current_tenant_id() and q.id = p_request_id and q.object_type = 'document'
     -- The stock documents only (20260928200000): a requisition's approval is
     -- taken over lines its buyer may still correct while it waits, which is
     -- a separate decision.
     and dt.base_type_code in ('transfer_order', 'adjustment')
$$;

revoke all on function erp.document_changed_since_request(uuid) from public, anon;

comment on function erp.document_changed_since_request(uuid) is
  'Whether a transfer order''s or stock adjustment''s lines or its chain''s material fields have changed '
  'since the approval request was made (20260928200000).';

create or replace function erp.approval_asked_nobody(p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- True when the approval a document's submit asked for asked nobody
  -- (20260928200000): none is pending, and its type names no chain, or the
  -- newest request for it approved itself because no step of the chain
  -- applied. Read by erp.approve_transfer_within_threshold() and, with the
  -- order's state locked, by erp.derived_move_fact(). A request any person
  -- decided, or was asked to decide, is not this.
  select coalesce((
    select case
             -- A request waiting on somebody asked somebody, whatever the type
             -- names now.
             when exists (select 1 from erp.approval_request q
                           where q.tenant_id = d.tenant_id and q.object_type = 'document'
                             and q.object_id = d.id and q.status = 'pending') then false
             when dt.approval_chain_code is null then true
             else exists (select 1 from erp.approval_request q
                           where q.tenant_id = d.tenant_id and q.object_type = 'document'
                             and q.object_id = d.id and q.status = 'approved'
                             and q.requested_at = (select max(q2.requested_at) from erp.approval_request q2
                                                    where q2.tenant_id = d.tenant_id
                                                      and q2.object_type = 'document'
                                                      and q2.object_id = d.id
                                                      and q2.status <> 'superseded')
                             and not exists (select 1 from erp.approval_task t
                                              where t.tenant_id = q.tenant_id
                                                and t.approval_request_id = q.id
                                                and t.status <> 'skipped'))
           end
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id), false)
$$;

revoke all on function erp.approval_asked_nobody(uuid) from public, anon;

comment on function erp.approval_asked_nobody(uuid) is
  'True when the approval a document''s submit asked for asked nobody: no chain on its type, or its '
  'newest request approved itself with no step applying and none pending (20260928200000). The fact '
  'a transfer order''s approve_within_threshold is derived from.';

create or replace function erp.transfer_is_received_in_full(p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- A transfer order whose goods have arrived, all of them (20260928200000):
  -- an arrival leg at the receiving site, and nothing left in transit, read
  -- the way erp.stock_state_refusal() reads the close (20260928000000). The
  -- fact a version 2 transfer's close is derived from.
  select exists (select 1 from erp.stock_movement m
                  where m.tenant_id = d.tenant_id and m.document_id = d.id
                    and m.site_id = d.destination_site_id and not m.is_reversal)
     and erp.transfer_in_transit_quantity(d.id) = 0
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id
     and dt.base_type_code = 'transfer_order'
$$;

revoke all on function erp.transfer_is_received_in_full(uuid) from public, anon;

comment on function erp.transfer_is_received_in_full(uuid) is
  'True when a transfer order''s goods have arrived at the receiving site and nothing is left in '
  'transit (20260928200000): the fact its close is derived from.';

create or replace function erp.document_declares_move(p_document_id uuid, p_transition_code text)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- Whether the version of the lifecycle a document is on declares this move
  -- out of the state it stands in (20260928200000), so a routine asks the
  -- version and not the code: a version 1 transfer order declares no submit
  -- and no close, and is left as it is.
  select exists (
    select 1
      from erp.object_state os
      join erp.transition t
        on t.tenant_id = os.tenant_id
       and t.state_machine_version_id = os.state_machine_version_id
       and t.from_state_id = os.current_state_id
     where os.tenant_id = erp.current_tenant_id()
       and os.object_type = 'document' and os.object_id = p_document_id
       and t.code = p_transition_code)
$$;

revoke all on function erp.document_declares_move(uuid, text) from public, anon;

comment on function erp.document_declares_move(uuid, text) is
  'Whether the lifecycle version a document is on declares the move out of the state it stands in '
  '(20260928200000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. The lifecycle, the chain and the document type, from one helper
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.transfer_order_pack_items()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- Version 2 of the transfer order (20260928200000), read by
  -- erp.configure_inventory() for a new install and by the upgrade register
  -- for an organisation on inventory-operations 7 or earlier, so the two
  -- cannot disagree. Every move asks inventory.move; the chain's one step
  -- applies to nothing until the organisation sets its threshold.
  select jsonb_build_array(
    jsonb_build_object('kind', 'state_machine', 'key', 'transfer_order', 'payload',
      jsonb_build_object(
        'code', 'transfer_order', 'object_type', 'document', 'name', 'Transfer order',
        'states', jsonb_build_array(
          jsonb_build_object('code','draft','name','Draft','is_initial',true,'is_terminal',false,'is_committed',false,'sort_order',10),
          jsonb_build_object('code','pending_approval','name','Pending approval','is_initial',false,'is_terminal',false,'is_committed',false,'sort_order',20),
          jsonb_build_object('code','approved','name','Approved','is_initial',false,'is_terminal',false,'is_committed',true,'sort_order',30),
          jsonb_build_object('code','issued','name','Issued','is_initial',false,'is_terminal',false,'is_committed',true,'sort_order',40),
          jsonb_build_object('code','in_transit','name','In transit','is_initial',false,'is_terminal',false,'is_committed',true,'sort_order',50),
          jsonb_build_object('code','received','name','Received','is_initial',false,'is_terminal',false,'is_committed',true,'sort_order',60),
          jsonb_build_object('code','closed','name','Closed','is_initial',false,'is_terminal',true,'is_committed',true,'sort_order',70),
          jsonb_build_object('code','cancelled','name','Cancelled','is_initial',false,'is_terminal',true,'is_committed',false,'sort_order',90)),
        'transitions', jsonb_build_array(
          jsonb_build_object('code','submit','name','Submit','from','draft','to','pending_approval','required_permission','inventory.move','sort_order',10,
                             'effects',jsonb_build_array(jsonb_build_object('kind','require_approval'))),
          jsonb_build_object('code','approve','name','Approve','from','pending_approval','to','approved','required_permission','inventory.move','sort_order',20),
          -- Derived from erp.approval_asked_nobody(), asked for by
          -- erp.approve_transfer_within_threshold() as the submit completes.
          jsonb_build_object('code','approve_within_threshold','name','Approve within threshold','from','pending_approval','to','approved','required_permission','inventory.move','is_automatic',true,'sort_order',22),
          jsonb_build_object('code','reject','name','Reject','from','pending_approval','to','draft','required_permission','inventory.move','sort_order',25),
          -- The despatch door's two moves, and the receive door's. Issued is
          -- the door's alone, derived as it loads: pressed by hand it would
          -- leave the transfer issued with nothing loaded and no way on or
          -- back. In transit and received are refused by erp.stock_state_
          -- refusal() over stock that has not moved (20260928000000).
          jsonb_build_object('code','issued','name','Issued','from','approved','to','issued','required_permission','inventory.move','is_automatic',true,'sort_order',30),
          jsonb_build_object('code','in_transit','name','In transit','from','issued','to','in_transit','required_permission','inventory.move','sort_order',40),
          jsonb_build_object('code','received','name','Received','from','in_transit','to','received','required_permission','inventory.move','sort_order',50),
          -- Derived from erp.transfer_is_received_in_full(), asked for by
          -- erp.close_transfer_when_received().
          jsonb_build_object('code','close','name','Close','from','received','to','closed','required_permission','inventory.move','is_automatic',true,'sort_order',60),
          jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','inventory.move','sort_order',90),
          jsonb_build_object('code','cancel_approved','name','Cancel','from','approved','to','cancelled','required_permission','inventory.move','sort_order',95)))),
    jsonb_build_object('kind', 'approval_chain', 'key', 'transfer_order_value', 'payload',
      jsonb_build_object(
        'code', 'transfer_order_value', 'name', 'Transfer order value approval',
        'object_type', 'document',
        'applies_when', jsonb_build_object('==', jsonb_build_array(jsonb_build_object('var', 'document_type'), 'transfer_order')),
        'priority', 100,
        'value_field', 'value_at_cost_minor',
        -- Its lines: the value is read against the threshold, and a line
        -- changed after the request is a change the approval never saw.
        'material_fields', jsonb_build_array('line_fingerprint'),
        'steps', jsonb_build_array(
          -- Off until the organisation sets a threshold: the condition is
          -- then {">": [{"var": "value_at_cost_minor"}, <minor units>]}.
          jsonb_build_object('seq', 1, 'code', 'stock_controller', 'name', 'Stock controller',
                             'approver_kind', 'role', 'role', 'inventory', 'min_approvals', 1,
                             'condition', false)))),
    jsonb_build_object('kind', 'numbering_rule', 'key', 'transfer_order', 'payload',
      jsonb_build_object('code','transfer_order','prefix','TRF-','pad_to',6,
                         'reset_period','yearly','next_value',1)),
    jsonb_build_object('kind', 'document_type', 'key', 'transfer_order', 'payload',
      jsonb_build_object('code','transfer_order','base_type','transfer_order',
                         'name','Transfer order','numbering_rule','transfer_order',
                         'state_machine','transfer_order',
                         'approval_chain','transfer_order_value',
                         'stock_movement_type','transfer_despatch',
                         'create_permission','inventory.move')))
$$;

comment on function erp.transfer_order_pack_items() is
  'The transfer order as inventory-operations version 8 installs it (20260928200000): version 2 of its '
  'lifecycle, the value chain whose threshold is off until set, its numbering rule and its document '
  'type, the items erp.configure_inventory() and the upgrade register both read.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. The upgrade register: version 8 for an organisation on version 7
-- ─────────────────────────────────────────────────────────────────────────────

update erp_ref.module_installer
   set current_version = 8,
       description = description
         || ' Version 8 (20260928200000): a transfer order is approved as it is raised unless its '
         || 'value at cost is over the organisation''s threshold, every move asks a permission, and it '
         || 'closes when its goods have all arrived.'
 where install_code = 'inventory-operations' and current_version = 7;

-- The lifecycle, the chain and the type. The numbering rule is unchanged.
insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
select 'inventory-operations', 8, i.value ->> 'kind', i.value ->> 'key', i.value -> 'payload',
       250 + 10 * i.ordinality::integer
  from jsonb_array_elements(erp.transfer_order_pack_items()) with ordinality as i(value, ordinality)
 where i.value ->> 'kind' <> 'numbering_rule'
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

do $register$
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'inventory-operations') is distinct from 8 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the inventory-operations installer is not at version 8';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       join jsonb_array_elements(erp.transfer_order_pack_items()) i
         on i.value ->> 'kind' = ui.object_kind and i.value ->> 'key' = ui.object_key
        and i.value -> 'payload' = ui.payload
      where ui.install_code = 'inventory-operations' and ui.to_version = 8) <> 3
     or (select count(*) from erp_ref.module_upgrade_item ui
          where ui.install_code = 'inventory-operations' and ui.to_version = 8) <> 3
     or not exists (select 1 from erp_ref.module_upgrade_item ui
                     where ui.install_code = 'inventory-operations' and ui.to_version = 8
                       and ui.object_kind = 'state_machine' and ui.object_key = 'transfer_order') then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 8 of inventory-operations is not the transfer order''s lifecycle, chain and type';
  end if;
end
$register$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. The base pack no longer ships the transfer order (D8)
--
-- Its copy declared no permission on any move, and the installer has shipped
-- the lifecycle since 20260917130000. The installer is the one source. An
-- organisation that applied the pack keeps what it holds; the pack simply
-- stops offering a second, weaker copy.
-- ─────────────────────────────────────────────────────────────────────────────

delete from erp_ref.pack_item pi
 where pi.pack_code = 'base' and pi.object_kind = 'state_machine' and pi.object_key = 'transfer_order';

-- ─────────────────────────────────────────────────────────────────────────────
-- A6. The approval context carries the value at cost
-- ─────────────────────────────────────────────────────────────────────────────

do $context$
declare
  v_sig constant text := 'erp.document_transition_context(uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := E'\n  return v_ctx;\nend;\n';
  v_new constant text :=
       E'\n  -- A transfer order''s and a stock adjustment''s lines carry no price, so\n'
    || E'  -- what they are worth is what their stock costs where it stands\n'
    || E'  -- (20260928200000): the value an approval threshold on either reads.\n'
    || E'  if dt.base_type_code in (''transfer_order'', ''adjustment'') then\n'
    || E'    v_ctx := v_ctx || jsonb_build_object(''value_at_cost_minor'', erp.document_value_at_cost_minor(p_document_id));\n'
    || E'  end if;\n'
    || E'\n  return v_ctx;\nend;\n';
  v_hits integer;
begin
  if position('value_at_cost_minor' in v_def) > 0 then
    raise notice '% already carries value_at_cost_minor; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % return anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$context$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A7. The two facts, read again with the order's state locked
-- ─────────────────────────────────────────────────────────────────────────────

do $derived$
declare
  v_sig constant text := 'erp.derived_move_fact(text,uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$             then 'erp.count_task_is_approved'
$o$;
  v_new constant text := $n$             then 'erp.count_task_is_approved'
           -- A transfer order approved within its threshold, when the
           -- approval its submit asked for asked nobody (20260928200000),
           -- asked for by erp.approve_transfer_within_threshold().
           when dt.base_type_code = 'transfer_order' and p_transition_code = 'approve_within_threshold'
            and erp.object_current_state('document', p_object_id) = 'pending_approval'
            and erp.approval_asked_nobody(p_object_id)
             then 'erp.approval_asked_nobody'
           -- A transfer order approved or rejected as its approval request was
           -- decided under My approvals (20260928200000), asked for by
           -- erp.settle_approval_outcome().
           when dt.base_type_code = 'transfer_order' and p_transition_code in ('approve', 'reject')
            and erp.object_current_state('document', p_object_id) = 'pending_approval'
            and exists (select 1 from erp.approval_request q
                         where q.tenant_id = d.tenant_id and q.object_type = 'document'
                           and q.object_id = p_object_id
                           and q.status::text = case p_transition_code when 'approve' then 'approved' else 'rejected' end
                           and not exists (select 1 from erp.approval_request q2
                                            where q2.tenant_id = q.tenant_id and q2.object_type = 'document'
                                              and q2.object_id = q.object_id and q2.status = 'pending'))
             then 'erp.approval_request'
           -- A transfer order's issued, as its despatch loads it
           -- (20260928200000), asked for by erp.despatch_transfer().
           when dt.base_type_code = 'transfer_order' and p_transition_code = 'issued'
            and erp.object_current_state('document', p_object_id) = 'approved'
             then 'erp.despatch_transfer'
           -- A transfer order's close, once everything despatched has
           -- arrived (20260928200000), asked for by
           -- erp.close_transfer_when_received().
           when dt.base_type_code = 'transfer_order' and p_transition_code = 'close'
            and erp.object_current_state('document', p_object_id) = 'received'
            and erp.transfer_is_received_in_full(p_object_id)
             then 'erp.transfer_is_received_in_full'
$n$;
  v_hits integer;
begin
  if position('erp.transfer_is_received_in_full' in v_def) > 0 then
    raise notice '% already names the transfer order''s facts; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % count adjustment arm found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$derived$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A8. The two routines that make the derived moves
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.approve_transfer_within_threshold(p_document_id uuid)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_prev text;
  v_to   text;
begin
  -- A transfer order just submitted whose approval asked nobody is approved
  -- (20260928200000). Called by erp.transition_document() after every submit
  -- of a transfer order; returns the state reached, or null and does nothing
  -- to one whose version declares no such move from where it stands, or
  -- whose approval asked somebody. The move is the system's, derived from
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

revoke all on function erp.approve_transfer_within_threshold(uuid) from public, anon;

comment on function erp.approve_transfer_within_threshold(uuid) is
  'Approves a transfer order just submitted whose approval asked nobody (20260928200000): the '
  'system''s move, derived from erp.approval_asked_nobody().';

create or replace function erp.close_transfer_when_received(p_document_id uuid, p_reason text default null,
                                                            p_by_hand boolean default false)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_prev   text;
  v_to     text;
begin
  -- A transfer order whose goods have all arrived closes (20260928200000).
  -- Called by erp.transition_document() after a transfer order reaches
  -- received, and for a close asked for by hand, with p_by_hand. Returns the
  -- state reached, or null and does nothing to one whose version declares no
  -- close from where it stands (version 1, whose own close is left as it
  -- was).
  --
  -- By hand, the close is the receiving site's: inventory.move is asked at
  -- the receiving site and nowhere else (decision of 26 September), and the
  -- close then takes its authority at the despatching site from the fact, as
  -- the derived close does. The fact is read again by the move, with the
  -- order's state locked; goods still in transit are refused by
  -- erp.require_stock_backed_move() before anything moves.
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found or not erp.document_declares_move(p_document_id, 'close') then
    return null;
  end if;

  if p_by_hand then
    perform erp.authorise('inventory.move', d.entity_id, d.destination_site_id, null,
                          'document', p_document_id);
  end if;

  v_prev := coalesce(current_setting('erp.deriving_move', true), '');
  perform set_config('erp.deriving_move', p_document_id::text || ':close', true);
  v_to := erp.transition_document(p_document_id, 'close',
                                  coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'Received in full'));
  perform set_config('erp.deriving_move', v_prev, true);
  return v_to;
end;
$$;

revoke all on function erp.close_transfer_when_received(uuid, text, boolean) from public, anon;

comment on function erp.close_transfer_when_received(uuid, text, boolean) is
  'Closes a transfer order whose goods have all arrived (20260928200000): derived from '
  'erp.transfer_is_received_in_full() after the receive, and by hand for somebody who may move stock '
  'at the receiving site.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A9. erp.transition_document() asks them
--
-- Before M1's stock guard: approve_within_threshold only when nobody was
-- asked, and a close asked for by hand goes through the receiving site's
-- routine. At the end: a submit that asked nobody is approved, and a
-- received order whose goods have all arrived closes. Applied once: a body
-- that already asks them is left alone.
-- ─────────────────────────────────────────────────────────────────────────────

do $transition_document$
declare
  v_sig constant text := 'erp.transition_document(uuid, text, text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old_decl constant text := E'  v_stock_derived jsonb;\nbegin\n';
  v_new_decl constant text := E'  v_stock_derived jsonb;\n  v_transfer_to text;\nbegin\n';
  v_old constant text :=
       E'  -- A transfer order or stock adjustment moves because its stock did\n'
    || E'  -- (20260928000000): by what the state a move reaches means, not its code,\n';
  v_new constant text :=
       E'  -- A transfer order is approved within its threshold only when its\n'
    || E'  -- approval asked nobody, and closed by hand only by the receiving site\n'
    || E'  -- (20260928200000): erp.close_transfer_when_received() asks inventory.move\n'
    || E'  -- there and makes the close, which the fact then carries at the\n'
    || E'  -- despatching site. A version with no close of that name falls through.\n'
    || E'  if dt.base_type_code = ''transfer_order'' then\n'
    || E'    if p_transition_code = ''approve_within_threshold''\n'
    || E'       and erp.document_declares_move(p_document_id, ''approve_within_threshold'')\n'
    || E'       and not erp.approval_asked_nobody(p_document_id) then\n'
    || E'      raise exception\n'
    || E'        ''CLOVEERP_TRANSFER_AWAITS_APPROVAL: % is waiting for the approval its value asked for'',\n'
    || E'        coalesce(d.document_number, p_document_id::text)\n'
    || E'        using errcode = ''23514'',\n'
    || E'              hint = ''The people asked decide it under My approvals, and the transfer is approved or sent back to draft as they decide.'';\n'
    || E'    end if;\n'
    || E'    -- Issued is the despatch''s own move where the version says so: pressed\n'
    || E'    -- by hand it would stand issued with nothing loaded and no way on.\n'
    || E'    if p_transition_code = ''issued''\n'
    || E'       and coalesce(current_setting(''erp.deriving_move'', true), '''') <> p_document_id::text || '':issued''\n'
    || E'       and exists (select 1 from erp.object_state os\n'
    || E'                     join erp.transition t\n'
    || E'                       on t.tenant_id = os.tenant_id and t.state_machine_version_id = os.state_machine_version_id\n'
    || E'                      and t.from_state_id = os.current_state_id\n'
    || E'                    where os.tenant_id = v_tenant and os.object_type = ''document''\n'
    || E'                      and os.object_id = p_document_id and t.code = ''issued'' and t.is_automatic) then\n'
    || E'      raise exception\n'
    || E'        ''CLOVEERP_TRANSFER_LOADED_BY_ITS_DOOR: % is marked issued by its despatch, as the goods are loaded'',\n'
    || E'        coalesce(d.document_number, p_document_id::text)\n'
    || E'        using errcode = ''23514'',\n'
    || E'              hint = ''Despatch it from the Site transfers screen, which loads the goods and marks it issued and in transit in the same press.'';\n'
    || E'    end if;\n'
    || E'    if p_transition_code = ''close''\n'
    || E'       and coalesce(current_setting(''erp.deriving_move'', true), '''') <> p_document_id::text || '':close'' then\n'
    || E'      v_transfer_to := erp.close_transfer_when_received(p_document_id, p_reason, true);\n'
    || E'      if v_transfer_to is not null then\n'
    || E'        return v_transfer_to;\n'
    || E'      end if;\n'
    || E'    end if;\n'
    || E'  end if;\n'
    || E'\n'
    || E'  -- A transfer order or stock adjustment moves because its stock did\n'
    || E'  -- (20260928000000): by what the state a move reaches means, not its code,\n';
  v_old_end constant text := E'\n  return v_to;\nend;\n';
  v_new_end constant text :=
       E'\n  -- A transfer order moves on by itself (20260928200000): submitted with\n'
    || E'  -- nobody asked to approve it, it is approved within its threshold; received\n'
    || E'  -- with all of it arrived, it closes. Each routine reads the order afresh\n'
    || E'  -- and does nothing to one whose version declares no such move.\n'
    || E'  if dt.base_type_code = ''transfer_order'' and p_transition_code = ''submit'' then\n'
    || E'    v_to := coalesce(erp.approve_transfer_within_threshold(p_document_id), v_to);\n'
    || E'  elsif dt.base_type_code = ''transfer_order'' and v_to = ''received'' then\n'
    || E'    v_to := coalesce(erp.close_transfer_when_received(p_document_id, ''Received in full''), v_to);\n'
    || E'  end if;\n'
    || E'\n  return v_to;\nend;\n';
  v_hits integer;
begin
  if position('erp.close_transfer_when_received(' in v_def) > 0 then
    raise notice '% already closes a received transfer; left as it is', v_sig;
    return;
  end if;
  if position('erp.require_stock_backed_move(' in v_def) = 0 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % no longer asks M1''s stock guard (20260928000000)', v_sig;
  end if;
  foreach v_hits in array array[
      (length(v_def) - length(replace(v_def, v_old_decl, ''))) / length(v_old_decl),
      (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old),
      (length(v_def) - length(replace(v_def, v_old_end, ''))) / length(v_old_end)] loop
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % an anchor was found % time(s)', v_sig, v_hits;
    end if;
  end loop;
  v_def := replace(v_def, v_old_decl, v_new_decl);
  v_def := replace(v_def, v_old, v_new);
  v_def := replace(v_def, v_old_end, v_new_end);
  execute v_def;
end
$transition_document$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A10. Raising submits
-- ─────────────────────────────────────────────────────────────────────────────

do $raise$
declare
  v_sig constant text := 'erp.raise_transfer_order(uuid,uuid,jsonb,date,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := E'  select * into d from erp.document where tenant_id = v_tenant and id = v_id;\n';
  v_new constant text :=
       E'  -- Submitted as it is raised, where its lifecycle declares a submit\n'
    || E'  -- (20260928200000): approved at once when nobody need approve it, and\n'
    || E'  -- waiting for the people its value asked for otherwise. A draft with no\n'
    || E'  -- lines is left to be filled and submitted.\n'
    || E'  if v_added > 0 and erp.document_declares_move(v_id, ''submit'') then\n'
    || E'    perform erp.transition_document(v_id, ''submit'', ''Raised'');\n'
    || E'  end if;\n'
    || E'\n'
    || E'  select * into d from erp.document where tenant_id = v_tenant and id = v_id;\n';
  v_hits integer;
begin
  if position('erp.document_declares_move(' in v_def) > 0 then
    raise notice '% already submits as it raises; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % result anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$raise$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A11. An approved transfer is not amended (D6)
-- ─────────────────────────────────────────────────────────────────────────────

do $amend$
declare
  v_sig constant text := 'erp.amendment_allowed(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := E'  elsif coalesce(v_terminal, false) or d.is_cancelled then\n';
  v_new constant text :=
       E'  -- A transfer order is changed only as a draft (20260928200000): once it\n'
    || E'  -- is approved, or waiting for approval, what was approved is what moves,\n'
    || E'  -- and a quantity amended after it would move past its threshold.\n'
    || E'  elsif erp.transfer_is_past_draft(p_document_id) then\n'
    || E'    allowed := false;\n'
    || E'    cut_off := ''transfer_approved'';\n'
    || E'    detail := format(''the transfer order is %s, and is changed only as a draft: cancel an '' ||\n'
    || E'                     ''approved one and raise it again, or have one waiting for approval '' ||\n'
    || E'                     ''rejected back to draft'', coalesce(v_state, ''past its draft''));\n'
    || E'  elsif coalesce(v_terminal, false) or d.is_cancelled then\n';
  v_hits integer;
begin
  if position('transfer_approved' in v_def) > 0 then
    raise notice '% already refuses an approved transfer; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % terminal cut-off anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$amend$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A12. The demonstration's trunk run takes version 2's route
--
-- Raised, and so approved within its threshold, which the demonstration never
-- sets; despatched; received, and so closed. A demonstration still on
-- version 1 (its catch-up refused the upgrade) is approved by the click it
-- always was.
-- ─────────────────────────────────────────────────────────────────────────────

do $seeder$
declare
  v_sig constant text := 'erp.seed_demo_history(date,date,numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := E'        perform erp.transition_document(v_transfer, ''approved'', ''demonstration'');\n';
  v_new constant text :=
       E'        -- Approved as it was raised, on version 2 of its lifecycle\n'
    || E'        -- (20260928200000); by the click version 1 declares, on that.\n'
    || E'        if erp.document_declares_move(v_transfer, ''approved'') then\n'
    || E'          perform erp.transition_document(v_transfer, ''approved'', ''demonstration'');\n'
    || E'        end if;\n';
  v_hits integer;
begin
  if position('erp.document_declares_move(v_transfer' in v_def) > 0 then
    raise notice '% already takes version 2''s route; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % trunk run approval anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$seeder$;

-- The catch-up says what it did to transfers too. It already upgrades
-- inventory-operations whenever the register has something for it.
do $catch_up$
declare
  v_sig constant text := 'erp.demonstration_catch_up()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$'Inventory operations was not upgraded, so its counts move as they did: %s'$o$;
  v_new constant text := $n$'Inventory operations was not upgraded, so its counts and transfers move as they did: %s'$n$;
  v_hits integer;
begin
  if position(v_new in v_def) > 0 then
    raise notice '% already speaks of transfers; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % inventory note found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$catch_up$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A14. The despatch takes issued as the goods are loaded
-- ─────────────────────────────────────────────────────────────────────────────

do $despatch$
declare
  v_sig constant text := 'erp.despatch_transfer(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := E'    perform erp.transition_document(p_document_id, ''issued'', ''Loading'');\n';
  v_new constant text :=
       E'    -- The despatch''s own move, derived as it loads (20260928200000).\n'
    || E'    perform set_config(''erp.deriving_move'', p_document_id::text || '':issued'', true);\n'
    || E'    perform erp.transition_document(p_document_id, ''issued'', ''Loading'');\n'
    || E'    perform set_config(''erp.deriving_move'', '''', true);\n';
  v_hits integer;
begin
  if position(':issued' in v_def) > 0 then
    raise notice '% already derives issued; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % issued anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$despatch$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A15. Decided under My approvals, the transfer moves with the decision
--
-- As a count task does (20260927000000): the request settles approved or
-- rejected, and the transfer takes approve or reject, derived from it. On the
-- document itself the approver's press decides their task the same way, and
-- the press then finds the transfer already moved.
-- ─────────────────────────────────────────────────────────────────────────────

do $settle$
declare
  v_sig constant text := 'erp.settle_approval_outcome(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := E'    return case when v_moved > 0 then q.status::text end;\n  end if;\n\n  return null;\nend;\n';
  v_new constant text :=
       E'    return case when v_moved > 0 then q.status::text end;\n  end if;\n\n'
    || E'  -- A transfer order waiting on this request is approved or sent back to\n'
    || E'  -- draft with it (20260928200000), by the move its version declares, the\n'
    || E'  -- fact named immediately before it and put back after.\n'
    || E'  if q.object_type = ''document''\n'
    || E'     and exists (select 1 from erp.document d\n'
    || E'                   join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id\n'
    || E'                  where d.tenant_id = v_tenant and d.id = q.object_id\n'
    || E'                    and dt.base_type_code = ''transfer_order'')\n'
    || E'     and erp.object_current_state(''document'', q.object_id) = ''pending_approval''\n'
    || E'     and erp.document_declares_move(q.object_id,\n'
    || E'           case when q.status::text = ''approved'' then ''approve'' else ''reject'' end) then\n'
    || E'    perform set_config(''erp.deriving_move'', q.object_id::text || '':'' ||\n'
    || E'      case when q.status::text = ''approved'' then ''approve'' else ''reject'' end, true);\n'
    || E'    perform erp.transition_document(q.object_id,\n'
    || E'      case when q.status::text = ''approved'' then ''approve'' else ''reject'' end,\n'
    || E'      case when q.status::text = ''approved'' then ''Approved under My approvals''\n'
    || E'           else ''Rejected under My approvals'' end);\n'
    || E'    perform set_config(''erp.deriving_move'', '''', true);\n'
    || E'    return q.status::text;\n'
    || E'  end if;\n\n'
    || E'  return null;\nend;\n';
  v_hits integer;
begin
  if position('Approved under My approvals' in v_def) > 0 then
    raise notice '% already moves a transfer; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % end anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$settle$;

do $own$
declare
  v_sig constant text := 'erp.decide_own_approval_tasks(uuid,text,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := E'  return exists (select 1 from erp.approval_request q\n'
                      || E'                  where q.tenant_id = v_tenant and q.id = v_req and q.status = ''pending'');\n';
  v_new constant text := E'  -- Or the decision has moved the document already, as a transfer order\n'
                      || E'  -- moves with its request (20260928200000): the press is done.\n'
                      || E'  return exists (select 1 from erp.approval_request q\n'
                      || E'                  where q.tenant_id = v_tenant and q.id = v_req and q.status = ''pending'')\n'
                      || E'      or not erp.document_declares_move(p_document_id, p_transition_code);\n';
  v_hits integer;
begin
  if position('erp.document_declares_move(' in v_def) > 0 then
    raise notice '% already sees a document moved; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % return anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$own$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A16. A submitted transfer takes no new line, and is approved as it was asked
-- ─────────────────────────────────────────────────────────────────────────────

do $add_line$
declare
  v_sig constant text := 'erp.add_document_line(uuid,uuid,numeric,bigint,text,date)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := E'  -- A committed document is one the outside world has seen. Changing what it\n';
  v_new constant text :=
       E'  -- A transfer order is changed only as a draft (20260928200000): a line\n'
    || E'  -- added while it waits for approval would move with an approval given\n'
    || E'  -- for less.\n'
    || E'  if erp.transfer_is_past_draft(p_document_id) then\n'
    || E'    raise exception\n'
    || E'      ''CLOVEERP_TRANSFER_CHANGED_ONLY_AS_A_DRAFT: % has been submitted, so it takes no new line'',\n'
    || E'      d.document_number\n'
    || E'      using errcode = ''23514'',\n'
    || E'            hint = ''Have it rejected back to draft and change it there, or raise a second transfer for what is left.'';\n'
    || E'  end if;\n'
    || E'\n'
    || E'  -- A committed document is one the outside world has seen. Changing what it\n';
  v_hits integer;
begin
  if position('erp.transfer_is_past_draft(' in v_def) > 0 then
    raise notice '% already refuses a submitted transfer; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % committed anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$add_line$;

do $identity$
declare
  v_sig constant text := 'erp.set_line_stock_identity(uuid,uuid,uuid,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := E'  if exists (select 1 from erp.object_state os join erp.state s on s.id = os.current_state_id\n'
                      || E'              where os.tenant_id = v_tenant and os.object_type = ''document'' and os.object_id = d.id and s.is_committed) then\n';
  v_new constant text :=
       E'  -- A submitted transfer order is changed only once it is back in draft\n'
    || E'  -- (20260928200000).\n'
    || E'  if erp.transfer_is_past_draft(d.id) then\n'
    || E'    raise exception\n'
    || E'      ''CLOVEERP_TRANSFER_CHANGED_ONLY_AS_A_DRAFT: % has been submitted, so no stock is pinned to its lines now'',\n'
    || E'      d.document_number\n'
    || E'      using errcode = ''23514'',\n'
    || E'            hint = ''Have it rejected back to draft and change it there, or raise a second transfer for what is left.'';\n'
    || E'  end if;\n'
    || E'\n'
    || v_old;
  v_hits integer;
begin
  if position('erp.transfer_is_past_draft(' in v_def) > 0 then
    raise notice '% already refuses a submitted transfer; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % committed anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$identity$;

do $require$
declare
  v_sig constant text := 'erp.require_document_approval(uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := E'  -- Approved. Whoever asked does not approve it themselves once the\n';
  v_new constant text :=
       E'  -- Approved for what it said when it was asked (20260928200000): a\n'
    || E'  -- document whose lines, or the fields its chain names, have changed since\n'
    || E'  -- is not approved over what nobody was asked about.\n'
    || E'  if q.status = ''approved'' and erp.document_changed_since_request(q.id) then\n'
    || E'    raise exception ''CLOVEERP_DOCUMENT_CHANGED_SINCE_APPROVAL: % has changed since its approval was asked for'',\n'
    || E'      coalesce(v_number, p_document_id::text)\n'
    || E'      using errcode = ''23514'',\n'
    || E'            hint = ''Send it back to draft and submit it again, so that the approval is asked for what it now says.'';\n'
    || E'  end if;\n'
    || E'\n'
    || v_old;
  v_hits integer;
begin
  if position('erp.document_changed_since_request(' in v_def) > 0 then
    raise notice '% already asks whether the document changed; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % approved anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$require$;
-- ─────────────────────────────────────────────────────────────────────────────
-- A13. The register: version 2's moves, and the doors' moves the two versions
--      share
--
-- Restated whole, from 20260927200000, so the register the screens are held
-- to is read from one place.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.transition_in_use(p_machine_code text, p_transition_code text)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- Whether a version of a document lifecycle that is still in use declares
  -- the move (20260928200000): the version in force, or one a document is
  -- still on. Read by erp.transition_driver_register() for the rows it keeps
  -- only for a version being retired, and by erp.undriven_transition_report()
  -- so a row for a version documents are still on is not drift.
  select exists (
    select 1
      from erp.state_machine m
      join erp.state_machine_version v on v.tenant_id = m.tenant_id and v.state_machine_id = m.id
      join erp.transition t on t.tenant_id = v.tenant_id and t.state_machine_version_id = v.id
     where m.code = p_machine_code and m.object_type = 'document'
       and t.code = p_transition_code
       and (v.status = 'active'
            or exists (select 1 from erp.object_state os
                        where os.tenant_id = v.tenant_id and os.state_machine_version_id = v.id)))
$$;

revoke all on function erp.transition_in_use(text, text) from public, anon;

comment on function erp.transition_in_use(text, text) is
  'Whether a lifecycle version still in use, in force or with a document on it, declares the move '
  '(20260928200000).';

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

      -- A count's own adjustment is approved and posted by erp.post_count(),
      -- through erp.raise_count_adjustment(), both moves derived from
      -- erp.count_task_is_approved() whatever permission the organisation
      -- puts on them (20260927200000). It never waits on either, so neither
      -- is drawn for it; a hand-typed adjustment is approved and posted here.
      ('stock_adjustment',   'approve',                'screen', ''),
      ('stock_adjustment',   'post',                   'screen', ''),
      ('stock_adjustment',   'cancel',                 'screen', ''),
      ('stock_adjustment',   'approved_to_cancelled',  'screen', ''),

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
   where not (x.machine_code = 'transfer_order'
              and x.transition_code in ('approved', 'closed',
                                        'draft_to_discrepancy', 'approved_to_discrepancy', 'issued_to_discrepancy',
                                        'in_transit_to_discrepancy', 'received_to_discrepancy', 'discrepancy_to_received',
                                        'draft_to_cancelled', 'approved_to_cancelled', 'issued_to_cancelled',
                                        'in_transit_to_cancelled', 'received_to_cancelled'))
      or erp.transition_in_use(x.machine_code, x.transition_code)
$$;

-- The report takes a row for a version documents are still on as the register
-- saying what drives them, not as drift (20260928200000).
do $undriven$
declare
  v_sig constant text := 'erp.undriven_transition_report(jsonb)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := E'     and not exists (select 1 from declared d\n'
                      || E'                      where d.machine_code = r.machine_code\n'
                      || E'                        and d.transition_code = r.transition_code)\n';
  v_new constant text := E'     and not exists (select 1 from declared d\n'
                      || E'                      where d.machine_code = r.machine_code\n'
                      || E'                        and d.transition_code = r.transition_code)\n'
                      || E'     -- Nor one a version documents are still on declares (20260928200000).\n'
                      || E'     and not erp.transition_in_use(r.machine_code, r.transition_code)\n';
  v_hits integer;
begin
  if position('erp.transition_in_use(' in v_def) > 0 then
    raise notice '% already reads the versions in use; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % declared anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$undriven$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. Version 1, for the suites that walk documents in flight on it
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.transfer_order_v1_item()
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- Version 1 of the transfer order's lifecycle, as inventory-operations 4
  -- shipped it (20260917130000) and the upgrade register still holds it
  -- (20260928200000). For the suites that walk documents in flight on it.
  select ui.payload
    from erp_ref.module_upgrade_item ui
   where ui.install_code = 'inventory-operations' and ui.to_version = 4
     and ui.object_kind = 'state_machine' and ui.object_key = 'transfer_order'
$$;

revoke all on function erp_test.transfer_order_v1_item() from public, anon;

comment on function erp_test.transfer_order_v1_item() is
  'Version 1 of the transfer order''s lifecycle, from the upgrade register (20260928200000).';

create or replace function erp_test.transfer_order_on_version_1()
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_cs uuid;
  v_version uuid;
begin
  -- Puts the organisation's transfer orders back on version 1 of their
  -- lifecycle, as one configured before 20260928200000 holds it, through a
  -- change set promoted the way an upgrade promotes one. Documents raised
  -- after start on it. For a suite, inside its rolled-back block, in an
  -- organisation not yet live.
  v_cs := erp.create_change_set(
    format('zz-transfer-order-v1-%s', substr(md5(gen_random_uuid()::text), 1, 8)),
    'Transfer order, version 1',
    'Version 1 of the transfer order''s lifecycle, for a suite that walks documents in flight on it.');
  perform erp.add_change_set_item(v_cs, 'state_machine', 'transfer_order',
                                  erp_test.transfer_order_v1_item(), 'upsert', null,
                                  'version 1 of the transfer order''s lifecycle');
  perform erp.submit_change_set(v_cs);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);

  select v.id into v_version
    from erp.state_machine m
    join erp.state_machine_version v on v.tenant_id = m.tenant_id and v.state_machine_id = m.id
   where m.tenant_id = erp.require_tenant_id() and m.code = 'transfer_order' and v.status = 'active'
   order by v.version desc
   limit 1;
  return v_version;
end;
$$;

revoke all on function erp_test.transfer_order_on_version_1() from public, anon;

comment on function erp_test.transfer_order_on_version_1() is
  'Puts the organisation''s transfer orders back on version 1 of their lifecycle through a promoted '
  'change set, for a suite (20260928200000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B2. The suites version 2 changes the answer for
--
-- M1's suite walks version 1's documents, which is what it proves: it puts
-- its organisation on version 1 before raising any. The site transfer suite
-- takes the upgrade from version 3 and so arrives at version 2, raised
-- approved and received closed; the demonstration's transfers are closed; and
-- the base pack ships no lifecycle. Each keeps its cases.
-- ─────────────────────────────────────────────────────────────────────────────

do $ssg$
declare
  v_sig constant text := 'erp_test.stock_state_guard_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := E'    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);\n'
                   || E'    select e.base_currency into v_ccy from erp.entity e where e.id = r.entity_id;\n';
  b0 constant text := E'    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);\n'
                   || E'    select e.base_currency into v_ccy from erp.entity e where e.id = r.entity_id;\n'
                   || E'    -- The documents this suite walks are version 1''s, the lifecycle a\n'
                   || E'    -- transfer in flight still moves by (20260928200000); a new install\n'
                   || E'    -- ships version 2, which erp_test.transfer_order_suite walks.\n'
                   || E'    v_fixture := ''version 1 of the transfer order''''s lifecycle'';\n'
                   || E'    perform erp_test.transfer_order_on_version_1();\n';
  a1 constant text := $o$                   where m.tenant_id = r.tenant_id and m.code in ('transfer_order', 'stock_adjustment')) = 2;$o$;
  b1 constant text := $n$                   where m.tenant_id = r.tenant_id and m.code in ('transfer_order', 'stock_adjustment')) = 3;
    -- Three since 20260928200000: the transfer order's version 2 as installed,
    -- which declares a permission on every move, and version 1 again, which
    -- the documents here are on.$n$;
  n integer;
begin
  if position('erp_test.transfer_order_on_version_1()' in v_def) > 0 then
    raise notice '% already walks version 1; left as it is', v_sig;
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

do $sts$
declare
  v_sig constant text := 'erp_test.site_transfer_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := E'  passed := v_planned = 1\n';
  b0 constant text := E'  -- Two since 20260928200000: version 4''s type and version 8''s, which\n'
                   || E'  -- names the value chain.\n'
                   || E'  passed := v_planned = 2\n';
  a1 constant text := $o$              where i.tenant_id = v_tenant and i.install_code = 'inventory-operations') = 7;
  detail := format('%s transfer order document type(s) planned, organisation now at version %s (7 rather than 4 since the stock adjustment, the count task''s lifecycle and the count sheet joined the same installer)',$o$;
  b1 constant text := $n$              where i.tenant_id = v_tenant and i.install_code = 'inventory-operations') = 8;
  detail := format('%s transfer order document type(s) planned, organisation now at version %s (8 rather than 4 since the stock adjustment, the count task''s lifecycle, the count sheet and the transfer order''s second lifecycle joined the same installer)',$n$;
  a2 constant text := $o$  case_name := 'a transfer order names both sites, carries its lines and starts in draft';$o$;
  b2 constant text := $n$  case_name := 'a transfer order names both sites, carries its lines and is approved as it is raised, nobody being asked while no threshold is set';$n$;
  a3 constant text := E'        and (v_res ->> ''state'') = ''draft''\n';
  b3 constant text := E'        and (v_res ->> ''state'') = ''approved''\n';
  a4 constant text := E'  perform erp.transition_document(v_doc, ''approved'', ''suite'');\n';
  b4 constant text := E'  -- Approved as it was raised (20260928200000).\n';
  a5 constant text := E'  perform erp.transition_document(v_fifo_doc, ''approved'', ''suite'');\n';
  b5 constant text := E'  -- Approved as it was raised (20260928200000).\n';
  a7 constant text := E'  delete from erp.document_type dt\n'
                   || E'   where dt.tenant_id = v_tenant and dt.code = ''transfer_order'';\n';
  b7 constant text := E'  -- And its transfer orders on version 1 of their lifecycle, which is what\n'
                   || E'  -- such an organisation holds (20260928200000).\n'
                   || E'  perform erp_test.transfer_order_on_version_1();\n'
                   || E'  delete from erp.document_type dt\n'
                   || E'   where dt.tenant_id = v_tenant and dt.code = ''transfer_order'';\n';
  a8 constant text := $o$  perform erp.transition_document(v_doc, 'issued', 'clicked');
  case_name := 'a transfer clicked to issued says the warehouse is loading, and moves no stock';
  passed := erp.document_state_code(v_doc) = 'issued'$o$;
  b8 constant text := $n$  -- Refused since 20260928200000: on version 2 issued is the despatch's own
  -- move, made as it loads. The order is then put where a transfer issued
  -- by hand before could stand, which is what the next case starts from.
  v_moved_err := null;
  begin
    perform erp.transition_document(v_doc, 'issued', 'clicked');
    raise exception 'CLOVEERP_SUITE_CLICK_WENT_THROUGH';
  exception when others then v_moved_err := sqlerrm; end;
  perform erp.perform_transition('document', v_doc, 'issued', '{}'::jsonb, 'as a transfer issued by hand before could stand');
  case_name := 'a transfer is not clicked to issued, which its despatch marks as it loads, and moves no stock';
  passed := v_moved_err like 'CLOVEERP_TRANSFER_LOADED_BY_ITS_DOOR%'
        and erp.document_state_code(v_doc) = 'issued'$n$;
  a6 constant text := E'        and (v_res ->> ''state'') = ''received''\n';
  b6 constant text := E'        -- Received, and so closed (20260928200000).\n'
                   || E'        and (v_res ->> ''state'') = ''closed''\n';
  n integer;
begin
  if position('20260928200000' in v_def) > 0 then
    raise notice '% already walks version 2; left as it is', v_sig;
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
      raise exception 'CLOVEERP_ANCHOR_MOVED: % version 2 anchor found % time(s)', v_sig, n;
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
$sts$;

do $dsts$
declare
  v_sig constant text := 'erp_test.demo_site_transfer_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$     and (erp.document_state_code(d.id) is distinct from 'received'$o$;
  b0 constant text := $n$     and (erp.document_state_code(d.id) is distinct from 'closed'$n$;
  a1 constant text := $o$  case_name := 'every transfer was approved, loaded and booked in: received, with a leg off the shelf, out of transit and in at the far end for every line, and nothing left on the road';$o$;
  b1 constant text := $n$  -- Closed as it is received, on version 2 of its lifecycle (20260928200000).
  case_name := 'every transfer was approved as it was raised, loaded and booked in, and so closed, with a leg off the shelf, out of transit and in at the far end for every line, and nothing left on the road';$n$;
  n integer;
begin
  if position('20260928200000' in v_def) > 0 then
    raise notice '% already expects closed; left as it is', v_sig;
    return;
  end if;
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a0, ''))) / length(a0),
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % closed anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(v_def, a0, b0), a1, b1);
end
$dsts$;

do $sls$
declare
  v_sig constant text := 'erp_test.shipped_lifecycle_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$  return query select 'the base pack ships only the transfer order''s lifecycle, which the inventory installer also ships',
    v_keys = 'transfer_order', coalesce(v_keys, 'none');$o$;
  b0 constant text := $n$  -- None since 20260928200000 (D8): the inventory installer is the one
  -- source of the transfer order's.
  return query select 'the base pack ships no lifecycle: the transfer order''s is the inventory installer''s alone',
    v_keys is null, coalesce(v_keys, 'none');$n$;
  n integer;
begin
  if position('20260928200000' in v_def) > 0 then
    raise notice '% already expects no lifecycle in the base pack; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, a0, ''))) / length(a0);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % base pack anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, a0, b0);
end
$sls$;

-- Two count suites pinned the installer's current version as 7, where they
-- mean "the version that ships the count task's lifecycle or the count sheet,
-- or a later one"; 8 since 20260928200000. Each keeps its cases.
do $cls$
declare
  v_sig constant text := 'erp_test.count_lifecycle_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$          where mi.install_code = 'inventory-operations') = 7
$o$;
  b0 constant text := $n$          -- or later: 8 since 20260928200000, the transfer order's.
          where mi.install_code = 'inventory-operations') >= 7
$n$;
  n integer;
begin
  if position('8 since 20260928200000' in v_def) > 0 then
    raise notice '% already reads a later version; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, a0, ''))) / length(a0);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % current version anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, a0, b0);
end
$cls$;

do $css$
declare
  v_sig constant text := 'erp_test.count_sheet_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$          where mi.install_code = 'inventory-operations') = 7
$o$;
  b0 constant text := $n$          -- or later: 8 since 20260928200000, the transfer order's.
          where mi.install_code = 'inventory-operations') >= 7
$n$;
  a1 constant text := $o$      and (res ->> 'to_version')::integer = 7 and (res ->> 'promoted')::boolean
      and (select i.installer_version from erp.module_installation i
            where i.tenant_id = r.tenant_id and i.install_code = 'inventory-operations') = 7
$o$;
  b1 constant text := $n$      -- The installer's current version: 8 since 20260928200000.
      and (res ->> 'to_version')::integer = (select mi.current_version from erp_ref.module_installer mi
                                              where mi.install_code = 'inventory-operations')
      and (res ->> 'promoted')::boolean
      and (select i.installer_version from erp.module_installation i
            where i.tenant_id = r.tenant_id and i.install_code = 'inventory-operations')
          = (select mi.current_version from erp_ref.module_installer mi
              where mi.install_code = 'inventory-operations')
$n$;
  n integer;
begin
  if position('8 since 20260928200000' in v_def) > 0 then
    raise notice '% already reads a later version; left as it is', v_sig;
    return;
  end if;
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a0, ''))) / length(a0),
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % current version anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(v_def, a0, b0), a1, b1);
end
$css$;

do $sas$
declare
  v_sig constant text := 'erp_test.stock_adjustment_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$              -- 7 since 20260927100000, the count sheet.
              where i.tenant_id = v_tenant and i.install_code = 'inventory-operations') = 7;$o$;
  b0 constant text := $n$              -- 7 since 20260927100000, the count sheet; 8 since
              -- 20260928200000, the transfer order's second lifecycle.
              where i.tenant_id = v_tenant and i.install_code = 'inventory-operations') = 8;$n$;
  n integer;
begin
  if position('8 since' in v_def) > 0 then
    raise notice '% already expects version 8; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, a0, ''))) / length(a0);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % version anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, a0, b0);
end
$sas$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B3. The proof: erp_test.transfer_order_suite
--
-- An organisation installed today, with two sites of one company, stock at
-- the first, and six people: the administrator, a mover and an approver who
-- may move stock anywhere, one who may move it only at the receiving site,
-- one only at the despatching site, and one who may only read. Its transfer
-- orders are first put back on version 1 and the upgrade taken, so the
-- documents in flight are version 1's and every one raised after is version
-- 2's. Then a demonstration of its own is built for a week.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.transfer_order_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_hex     text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1        uuid := gen_random_uuid();   -- the administrator
  a_mov     uuid := gen_random_uuid();   -- moves stock anywhere
  a_app     uuid := gen_random_uuid();   -- moves stock anywhere, and approves
  a_rcv     uuid := gen_random_uuid();   -- moves stock at the receiving site only
  a_dsp     uuid := gen_random_uuid();   -- moves stock at the despatching site only
  a_obs     uuid := gen_random_uuid();   -- may only read
  a_demo    uuid := gen_random_uuid();   -- the demonstration's administrator
  r         record;
  rd        record;
  res       jsonb;
  v_ccy     char(3);
  v_uom     uuid; v_item uuid;
  s_a       uuid; s_b uuid; l_a uuid; l_b uuid;
  v_app     uuid; v_rcv uuid; v_mov uuid;
  u_draft   uuid; u_road uuid;
  t_off     uuid; t_draft uuid; t_m1 uuid; t_rs uuid; t_small uuid; t_big uuid; t_rej uuid; t_new uuid;
  t_add     uuid; t_edit uuid; t_mya uuid; t_myr uuid; t_nochain uuid; t_nocost uuid;
  v_task    uuid; v_item2 uuid;
  v_line    uuid;
  v_fixture text;
  v_got text; v_got2 text; v_got3 text; v_got4 text; v_got5 text;
  v_codes   text;
  v_bad     text;
  v_n integer; v_n2 integer;
  v_q numeric;
  v_log     jsonb;
  v_ok      boolean;
  v_from    date;
  v_owner   text := current_user;
begin
  begin
    v_fixture := 'provisioning';
    select * into r from erp.provision_tenant(
      'zz-tos-' || v_hex, 'Transfer order suite',
      'a@zz-tos-' || v_hex || '.test', 'Suite Admin');
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    v_fixture := 'installing';
    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);
    select e.base_currency into v_ccy from erp.entity e where e.id = r.entity_id;

    v_fixture := 'two sites and stock at the first';
    insert into erp.site (tenant_id, entity_id, code, name, site_type, country_code, status)
    values (r.tenant_id, r.entity_id, 'ZZ-A', 'Despatching', 'warehouse', 'GB', 'active') returning id into s_a;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, country_code, status)
    values (r.tenant_id, r.entity_id, 'ZZ-B', 'Receiving', 'warehouse', 'GB', 'active') returning id into s_b;
    insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
    values (r.tenant_id, s_a, 'ZZ-A-BULK', 'A bulk', 'bulk', true, 'active') returning id into l_a;
    insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
    values (r.tenant_id, s_b, 'ZZ-B-IN', 'B in', 'receiving', false, 'active') returning id into l_b;
    select u.id into v_uom from erp.uom u where u.tenant_id = r.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'ZZ-T', 'Widget', v_uom, 'active') returning id into v_item;
    perform erp.receive_cost(v_item, s_a, 200, 500, v_ccy);
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, to_location_id,
      to_status, quantity, uom_id, unit_cost_minor, currency, reason_code)
    values (r.tenant_id, r.entity_id, s_a, 'receipt_no_order', v_item, l_a, 'available', 200, v_uom, 500,
      v_ccy, 'OPENING');

    v_fixture := 'the people';
    res := public.erp_invite_principal('mover@zz-tos-' || v_hex || '.test', 'Mo Mover');
    v_mov := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(v_mov, 'inventory', null, null, 'moves stock');
    perform set_config('request.jwt.claims', json_build_object('sub', a_mov)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('approver@zz-tos-' || v_hex || '.test', 'Ada Approver');
    v_app := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(v_app, 'inventory', null, null, 'moves stock and approves transfers');
    perform set_config('request.jwt.claims', json_build_object('sub', a_app)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('receiver@zz-tos-' || v_hex || '.test', 'Rae Receiver');
    v_rcv := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(v_rcv, 'inventory', r.entity_id, s_b, 'moves stock at the receiving site');
    perform set_config('request.jwt.claims', json_build_object('sub', a_rcv)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('despatcher@zz-tos-' || v_hex || '.test', 'Des Patcher');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'inventory', r.entity_id, s_a, 'moves stock at the despatching site');
    perform set_config('request.jwt.claims', json_build_object('sub', a_dsp)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('reader@zz-tos-' || v_hex || '.test', 'Stock Reader');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'observer', null, null, 'reads the stock');
    perform set_config('request.jwt.claims', json_build_object('sub', a_obs)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- ── 1. Installed today, it is version 2 ─────────────────────────────────
    v_fixture := 'the install';
    select string_agg(t.code, ',' order by t.code),
           count(*) filter (where t.required_permission is distinct from 'inventory.move'),
           count(*) filter (where ts.code = 'discrepancy' or fs.code = 'discrepancy'
                              or (ts.code = 'cancelled' and fs.code in ('issued', 'in_transit', 'received')))
      into v_codes, v_n, v_n2
      from erp.state_machine m
      join erp.state_machine_version v on v.tenant_id = m.tenant_id and v.state_machine_id = m.id and v.status = 'active'
      join erp.transition t on t.tenant_id = v.tenant_id and t.state_machine_version_id = v.id
      join erp.state fs on fs.id = t.from_state_id
      join erp.state ts on ts.id = t.to_state_id
     where m.tenant_id = r.tenant_id and m.code = 'transfer_order';
    select string_agg(s.code, ',' order by s.code) into v_bad
      from erp.state_machine m
      join erp.state_machine_version v on v.tenant_id = m.tenant_id and v.state_machine_id = m.id and v.status = 'active'
      join erp.state s on s.tenant_id = v.tenant_id and s.state_machine_version_id = v.id
     where m.tenant_id = r.tenant_id and m.code = 'transfer_order'
       and not s.is_initial
       and not exists (select 1 from erp.transition t where t.state_machine_version_id = v.id and t.to_state_id = s.id);
    select string_agg(format('%s/%s/%s', st.code, rl.code, st.condition), ',') into v_got
      from erp.approval_chain ac
      join erp.approval_chain_version acv on acv.tenant_id = ac.tenant_id and acv.approval_chain_id = ac.id and acv.status = 'active'
      join erp.approval_step st on st.tenant_id = acv.tenant_id and st.approval_chain_version_id = acv.id
      left join erp.role rl on rl.id = st.role_id
     where ac.tenant_id = r.tenant_id and ac.code = 'transfer_order_value'
       and acv.value_field = 'value_at_cost_minor';
    case_name := 'a new organisation installs version 2: ten moves, each asking inventory.move, no discrepancy and no cancellation once loaded, every state entered, and a value chain for the inventory role that asks nobody until a threshold is set';
    passed := coalesce(v_codes = 'approve,approve_within_threshold,cancel,cancel_approved,close,in_transit,issued,received,reject,submit'
              and v_n = 0 and v_n2 = 0 and v_bad is null
              and v_got = 'stock_controller/inventory/false'
              and (select dt.approval_chain_code from erp.document_type dt
                    where dt.tenant_id = r.tenant_id and dt.code = 'transfer_order') = 'transfer_order_value'
              and (select i.installer_version from erp.module_installation i
                    where i.tenant_id = r.tenant_id and i.install_code = 'inventory-operations') = 8, false);
    detail := format('moves %s; %s without inventory.move; %s into discrepancy or cancelled once loaded; states with no way in: %s; chain steps %s',
                     coalesce(v_codes, 'none'), v_n, v_n2, coalesce(v_bad, 'none'), coalesce(v_got, 'none'));
    return next;

    -- ── 2. An organisation on version 7 takes version 8 from the register ───
    -- Put back where an organisation configured before today stands: its
    -- transfers on version 1, no value chain, its type naming none, the
    -- module at 7. Documents raised then are version 1's.
    v_fixture := 'back to version 7';
    perform erp_test.transfer_order_on_version_1();
    update erp.document_type set approval_chain_code = null
     where tenant_id = r.tenant_id and code = 'transfer_order';
    update erp.approval_chain set code = 'zz_before_' || v_hex, status = 'inactive'
     where tenant_id = r.tenant_id and code = 'transfer_order_value';
    update erp.module_installation set installer_version = 7
     where tenant_id = r.tenant_id and install_code = 'inventory-operations';
    u_draft := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 2))) ->> 'document_id')::uuid;
    u_road  := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 3))) ->> 'document_id')::uuid;
    perform erp.transition_document(u_road, 'approved', null);
    perform erp.despatch_transfer(u_road);
    v_got2 := erp.document_state_code(u_draft);
    v_fixture := 'the upgrade';
    select string_agg(p.object_kind || ':' || p.object_key, ',' order by p.object_kind) into v_got
      from erp.plan_module_upgrade('inventory-operations') p;
    res := erp.upgrade_module_configuration('inventory-operations');
    t_new := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 1))) ->> 'document_id')::uuid;
    case_name := 'an organisation on version 7 is offered the lifecycle, the chain and the type, takes them through the upgrade, and a transfer raised after is version 2''s, approved as it is raised';
    passed := coalesce(v_got = 'approval_chain:transfer_order_value,document_type:transfer_order,state_machine:transfer_order'
              and (res ->> 'promoted')::boolean
              and v_got2 = 'draft'
              and erp.document_state_code(t_new) = 'approved'
              and erp.document_declares_move(u_draft, 'approved')
              and not erp.document_declares_move(u_draft, 'submit')
              and (select i.installer_version from erp.module_installation i
                    where i.tenant_id = r.tenant_id and i.install_code = 'inventory-operations') = 8
              and (select dt.approval_chain_code from erp.document_type dt
                    where dt.tenant_id = r.tenant_id and dt.code = 'transfer_order') = 'transfer_order_value', false);
    detail := format('planned %s; %s; a version 1 transfer raised before stood %s; one raised after is %s',
                     coalesce(v_got, 'nothing'), res, v_got2, erp.document_state_code(t_new));
    return next;

    -- ── 3. And the version 1 transfers in flight still move as they did ────
    v_fixture := 'version 1 in flight';
    v_got  := erp_test.stock_state_try(u_draft, 'draft_to_discrepancy');
    perform erp.transition_document(u_draft, 'approved', 'approved the way version 1 is');
    v_got2 := erp.document_state_code(u_draft);
    res := erp.receive_transfer(u_road);
    v_got3 := res ->> 'state';
    perform erp.transition_document(u_road, 'closed', 'closed the way version 1 is');
    v_got4 := erp.document_state_code(u_road);
    case_name := 'a version 1 transfer in flight is approved by its own click, received but not closed by the receive, closed by hand, and still refused discrepancy';
    passed := coalesce(v_got like 'CLOVEERP_TRANSFER_DISCREPANCY_RETIRED%'
              and v_got2 = 'approved' and v_got3 = 'received' and v_got4 = 'closed'
              and not exists (select 1 from erp.state_transition_log l
                               where l.tenant_id = r.tenant_id and l.object_id = u_road
                                 and l.transition_code = 'close'), false);
    detail := format('discrepancy: %s; approved: %s; received: %s; then %s', left(v_got, 60), v_got2, v_got3, v_got4);
    return next;

    -- ── 4. With no threshold set, nobody is asked ───────────────────────────
    v_fixture := 'no threshold';
    perform set_config('request.jwt.claims', json_build_object('sub', a_mov)::text, true);
    res := erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 5)));
    t_off := (res ->> 'document_id')::uuid;
    select string_agg(l.transition_code || coalesce('[' || (l.guard_data -> 'derived' ->> 'fact') || ']', ''), ',' order by l.id)
      into v_codes
      from erp.state_transition_log l where l.tenant_id = r.tenant_id and l.object_id = t_off;
    select string_agg(q.status::text || ' ' || coalesce(q.context ->> 'value_at_cost_minor', '-') || ' '
                      || (select count(*) from erp.approval_task t where t.approval_request_id = q.id and t.status <> 'skipped'), ';')
      into v_got
      from erp.approval_request q where q.tenant_id = r.tenant_id and q.object_id = t_off;
    case_name := 'with no threshold set, a transfer is raised approved: submitted, and approved within its threshold on the fact that nobody was asked, its value at cost in the request';
    passed := coalesce(res ->> 'state' = 'approved'
              and v_codes = 'submit,approve_within_threshold[erp.approval_asked_nobody]'
              and v_got = 'approved 2500 0', false);
    detail := format('raised %s; moves %s; request %s', res ->> 'state', v_codes, coalesce(v_got, 'none'));
    return next;

    -- ── 5. An approved transfer is not amended ──────────────────────────────
    v_fixture := 'amending';
    t_draft := (erp.raise_transfer_order(s_a, s_b, '[]'::jsonb) ->> 'document_id')::uuid;
    perform erp.add_document_line(t_draft, v_item, 2, 0, null, null);
    select l.id into v_line from erp.document_line l where l.tenant_id = r.tenant_id and l.document_id = t_draft;
    begin
      perform erp.amend_document_line(v_line, 3, 'the other site wants one more');
      v_got := 'went through';
    exception when others then v_got := sqlerrm; end;
    select l.id into v_line from erp.document_line l where l.tenant_id = r.tenant_id and l.document_id = t_off;
    begin
      perform erp.amend_document_line(v_line, 40, 'made bigger after its approval');
      v_got2 := 'went through';
    exception when others then v_got2 := sqlerrm; end;
    case_name := 'a draft transfer is amended, and an approved one is refused: what was approved is what moves';
    passed := coalesce(v_got = 'went through'
              and v_got2 like 'CLOVEERP_PAST_AMENDMENT_CUT_OFF: transfer_approved%'
              and (select sum(l.quantity) from erp.document_line l where l.document_id = t_off) = 5
              and erp.document_state_code(t_draft) = 'draft', false);
    detail := format('draft: %s; approved: %s', v_got, left(v_got2, 120));
    return next;

    -- ── 6. Every move asks its permission ───────────────────────────────────
    v_fixture := 'the reader';
    perform set_config('request.jwt.claims', json_build_object('sub', a_obs)::text, true);
    v_got  := erp_test.stock_state_try(t_draft, 'submit');
    v_got2 := erp_test.stock_state_try(t_draft, 'cancel');
    v_got3 := erp_test.stock_state_try(t_off, 'cancel_approved');
    begin
      perform erp.despatch_transfer(t_off);
      v_got4 := 'went through';
    exception when others then v_got4 := sqlerrm; end;
    select count(*) into v_n
      from (select x from jsonb_array_elements(public.erp_available_transitions(t_draft)) x
            union all
            select x from jsonb_array_elements(public.erp_available_transitions(t_off)) x) y
     where (y.x ->> 'permitted')::boolean;
    perform set_config('request.jwt.claims', json_build_object('sub', a_mov)::text, true);
    v_got5 := erp_test.stock_state_try(t_draft, 'submit');
    case_name := 'every move of version 2 asks inventory.move of the lifecycle itself: somebody who may only read is refused each and offered none, and a mover is not';
    passed := coalesce(v_got like 'CLOVEERP_PERMISSION_DENIED: inventory.move%'
              and v_got2 like 'CLOVEERP_PERMISSION_DENIED: inventory.move%'
              and v_got3 like 'CLOVEERP_PERMISSION_DENIED: inventory.move%'
              and v_got4 like 'CLOVEERP_PERMISSION_DENIED: inventory.move%'
              and v_n = 0 and v_got5 = 'went through', false);
    detail := format('submit %s; cancel %s; cancel approved %s; despatch %s; %s offered; the mover''s submit %s',
                     left(v_got, 50), left(v_got2, 50), left(v_got3, 50), left(v_got4, 50), v_n, v_got5);
    return next;

    -- ── 7. Received in full, it closes itself ───────────────────────────────
    v_fixture := 'the derived close';
    perform erp.despatch_transfer(t_off);
    res := erp.receive_transfer(t_off);
    select string_agg(l.transition_code || coalesce('[' || (l.guard_data -> 'derived' ->> 'fact') || ']', ''), ',' order by l.id)
      into v_codes
      from erp.state_transition_log l where l.tenant_id = r.tenant_id and l.object_id = t_off;
    select coalesce(sum(m.quantity), 0) into v_q
      from erp.stock_movement m
     where m.tenant_id = r.tenant_id and m.document_id = t_off and m.site_id = s_b and m.to_status = 'available';
    case_name := 'a transfer despatched and received closes in the receive, on the fact that it all arrived, with nobody pressing Close';
    passed := coalesce(res ->> 'state' = 'closed'
              and v_codes = 'submit,approve_within_threshold[erp.approval_asked_nobody],issued[erp.despatch_transfer],in_transit,received,close[erp.transfer_is_received_in_full]'
              and erp.transfer_in_transit_quantity(t_off) = 0 and v_q = 5, false);
    detail := format('the receive left it %s; moves %s; %s available at the receiving site', res ->> 'state', v_codes, trim_scale(v_q));
    return next;

    -- ── 8. M1's refusals hold on version 2 ─────────────────────────────────
    v_fixture := 'the stock guard on version 2';
    t_m1 := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 4))) ->> 'document_id')::uuid;
    v_got  := erp_test.stock_state_try(t_m1, 'received');
    v_bad  := 'approved: ' || erp_test.stock_state_menu_disagrees(t_m1);
    -- Where a transfer issued by hand before 20260928200000 could stand:
    -- issued, with nothing loaded. It is not put on the road over nothing.
    perform erp.perform_transition('document', t_m1, 'issued', '{}'::jsonb, 'as one issued by hand could stand');
    v_got4 := erp_test.stock_state_try(t_m1, 'in_transit');
    v_bad  := concat_ws('; ', v_bad, 'issued: ' || erp_test.stock_state_menu_disagrees(t_m1));
    perform erp.despatch_transfer(t_m1);
    v_got2 := erp_test.stock_state_try(t_m1, 'received');
    v_got3 := erp_test.stock_state_try(t_m1, 'close');
    v_bad  := concat_ws('; ', v_bad, 'in transit: ' || erp_test.stock_state_menu_disagrees(t_m1));
    case_name := 'on version 2 a transfer is still not received over nothing or while on the road, nor put on the road with nothing loaded, nor closed on the road, and the screen offers only what the door takes';
    passed := coalesce(v_got like 'CLOVEERP_TRANSFER_HAS_NOT_MOVED%'
              and v_got4 like 'CLOVEERP_TRANSFER_HAS_NOT_MOVED%left the despatching site%'
              and v_got2 like 'CLOVEERP_TRANSFER_HAS_NOT_MOVED%'
              and v_got3 like 'CLOVEERP_TRANSITION_NOT_PERMITTED%'
              and coalesce(v_bad, '') in ('approved: ; issued: ; in transit: ', '')
              and erp.document_state_code(t_m1) = 'in_transit', false);
    detail := format('received when approved: %s; on the road with nothing loaded: %s; received on the road: %s; close on the road: %s; menu %s',
                     left(v_got, 60), left(v_got4, 60), left(v_got2, 60), left(v_got3, 60), coalesce(v_bad, 'agrees'));
    return next;

    -- ── 9. Discrepancy is gone, and so are the cancellations once loaded ────
    v_fixture := 'the retired moves';
    v_got  := erp_test.stock_state_try(t_draft, 'draft_to_discrepancy');
    v_got2 := erp_test.stock_state_try(t_m1, 'in_transit_to_discrepancy');
    v_got3 := erp_test.stock_state_try(t_m1, 'in_transit_to_cancelled');
    v_got4 := erp_test.stock_state_try(t_m1, 'cancel_approved');
    case_name := 'version 2 has no discrepancy and no cancellation on the road: each is a move it does not declare';
    passed := coalesce(v_got like 'CLOVEERP_TRANSITION_NOT_PERMITTED%'
              and v_got2 like 'CLOVEERP_TRANSITION_NOT_PERMITTED%'
              and v_got3 like 'CLOVEERP_TRANSITION_NOT_PERMITTED%'
              and v_got4 like 'CLOVEERP_TRANSITION_NOT_PERMITTED%', false);
    detail := format('into discrepancy: %s; from the road: %s; cancelled on the road: %s; cancel approved on the road: %s',
                     left(v_got, 50), left(v_got2, 50), left(v_got3, 50), left(v_got4, 50));
    return next;

    -- ── 10. The receiving site closes it on its own ─────────────────────────
    -- A version 2 transfer that reached received without its close: arrived,
    -- all of it, and the close not taken.
    v_fixture := 'the receiving site''s close';
    t_rs := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 2))) ->> 'document_id')::uuid;
    perform erp.despatch_transfer(t_rs);
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, from_location_id, from_status,
      quantity, uom_id, unit_cost_minor, currency, document_id, document_line_id)
    select m.tenant_id, m.entity_id, m.site_id, 'transfer_out', m.item_id, m.to_location_id, 'in_transit',
           m.quantity, m.uom_id, m.unit_cost_minor, m.currency, m.document_id, m.document_line_id
      from erp.stock_movement m
     where m.tenant_id = r.tenant_id and m.document_id = t_rs and m.to_status = 'in_transit';
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency, document_id, document_line_id)
    select m.tenant_id, m.entity_id, s_b, 'transfer_in', m.item_id, l_b, 'available',
           m.quantity, m.uom_id, m.unit_cost_minor, m.currency, m.document_id, m.document_line_id
      from erp.stock_movement m
     where m.tenant_id = r.tenant_id and m.document_id = t_rs and m.to_status = 'in_transit';
    perform erp.perform_transition('document', t_rs, 'received', '{}'::jsonb, 'arrived without its close');
    perform set_config('request.jwt.claims', json_build_object('sub', a_dsp)::text, true);
    v_got  := erp_test.stock_state_try(t_rs, 'close');
    perform set_config('request.jwt.claims', json_build_object('sub', a_rcv)::text, true);
    begin
      perform public.erp_receive_transfer(t_m1);
      v_got2 := 'went through';
    exception when others then v_got2 := sqlerrm; end;
    v_got3 := public.erp_transition_document(t_rs, 'close', 'booked in here') ->> 'state';
    perform set_config('request.jwt.claims', json_build_object('sub', a_mov)::text, true);
    select l.guard_data -> 'derived' into v_log
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_id = t_rs and l.transition_code = 'close';
    case_name := 'somebody who may move stock only at the receiving site closes a transfer received in full, which the despatching site alone may not, and still may not receive one';
    passed := coalesce(v_got like 'CLOVEERP_PERMISSION_DENIED: inventory.move%'
              and v_got2 like 'CLOVEERP_PERMISSION_DENIED: inventory.move%'
              and v_got3 = 'closed'
              and v_log ->> 'fact' = 'erp.transfer_is_received_in_full'
              and not (v_log ->> 'actor_permitted')::boolean, false);
    detail := format('the despatching site''s close: %s; the receiving site''s receive: %s; its close: %s; logged %s',
                     left(v_got, 60), left(v_got2, 60), v_got3, coalesce(v_log::text, 'nothing derived'));
    return next;

    -- ── 11. With a threshold set, a large transfer waits for somebody else ──
    v_fixture := 'a threshold';
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_propose_approval_chain('transfer_order_value', 'Transfer order value approval', 'document',
      jsonb_build_array(jsonb_build_object('seq', 1, 'code', 'stock_controller', 'name', 'Stock controller',
        'role', 'inventory', 'min_approvals', 1,
        'condition', jsonb_build_object('>', jsonb_build_array(jsonb_build_object('var', 'value_at_cost_minor'), 1000)))),
      jsonb_build_object('==', jsonb_build_array(jsonb_build_object('var', 'document_type'), 'transfer_order')),
      'value_at_cost_minor', 100, 'a threshold of ten pounds at cost');
    v_ok := (res ->> 'in_force')::boolean;
    update erp.environment set is_live = true where tenant_id = r.tenant_id and is_self;
    perform set_config('request.jwt.claims', json_build_object('sub', a_mov)::text, true);
    t_small := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 1))) ->> 'document_id')::uuid;
    t_big   := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 5))) ->> 'document_id')::uuid;
    v_got  := erp.document_state_code(t_big);
    v_got2 := erp_test.stock_state_try(t_big, 'approve_within_threshold');
    v_got3 := erp_test.stock_state_try(t_big, 'approve');
    begin
      perform erp.despatch_transfer(t_big);
      v_got4 := 'went through';
    exception when others then v_got4 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a_app)::text, true);
    v_got5 := public.erp_transition_document(t_big, 'approve', 'fine by me') ->> 'state';
    select count(*) into v_n
      from erp.approval_task t
      join erp.approval_request q on q.id = t.approval_request_id
     where q.tenant_id = r.tenant_id and q.object_id = t_big and t.status <> 'skipped'
       and t.assignee_user_id = v_mov;
    perform set_config('request.jwt.claims', json_build_object('sub', a_mov)::text, true);
    perform erp.despatch_transfer(t_big);
    res := erp.receive_transfer(t_big);
    case_name := 'with a threshold set, a transfer under it is raised approved, and one over it waits: its raiser may not approve it within the threshold or at all, nor load it, and somebody else approves it and it moves';
    passed := coalesce(v_ok and erp.document_state_code(t_small) = 'approved'
              and v_got = 'pending_approval'
              and v_got2 like 'CLOVEERP_TRANSFER_AWAITS_APPROVAL%'
              and (v_got3 like 'CLOVEERP_DOCUMENT_APPROVAL_PENDING%' or v_got3 like 'CLOVEERP_DOCUMENT_SELF_APPROVAL%')
              and v_got4 like 'CLOVEERP_TRANSFER_NOT_READY%'
              and v_got5 = 'approved' and v_n = 0
              and res ->> 'state' = 'closed', false);
    detail := format('proposed %s; over the threshold %s; within the threshold: %s; the raiser''s approve: %s; loaded: %s; the approver: %s; then %s',
                     v_ok, v_got, left(v_got2, 50), left(v_got3, 60), left(v_got4, 40), v_got5, res ->> 'state');
    return next;

    -- ── 12. A rejected transfer goes back to draft ──────────────────────────
    v_fixture := 'a rejection';
    t_rej := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 6))) ->> 'document_id')::uuid;
    perform set_config('request.jwt.claims', json_build_object('sub', a_app)::text, true);
    v_got := public.erp_transition_document(t_rej, 'reject', 'too many at once') ->> 'state';
    perform set_config('request.jwt.claims', json_build_object('sub', a_mov)::text, true);
    select l.id into v_line from erp.document_line l where l.tenant_id = r.tenant_id and l.document_id = t_rej;
    perform erp.amend_document_line(v_line, 1, 'sent a smaller one');
    v_got2 := public.erp_transition_document(t_rej, 'submit', 'smaller now') ->> 'state';
    case_name := 'an approver rejects a transfer back to draft, where it is changed and submitted again, and under the threshold it is then approved';
    passed := coalesce(v_got = 'draft' and v_got2 = 'approved', false);
    detail := format('rejected to %s; submitted again to %s', v_got, v_got2);
    return next;

    -- ── 13. A submitted transfer takes no new line ──────────────────────────
    v_fixture := 'lines while waiting';
    t_add := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 5))) ->> 'document_id')::uuid;
    begin
      perform erp.add_document_line(t_add, v_item, 900, 0, null, null);
      v_got := 'went through';
    exception when others then v_got := sqlerrm; end;
    select l.id into v_line from erp.document_line l where l.tenant_id = r.tenant_id and l.document_id = t_add;
    begin
      perform erp.set_line_stock_identity(v_line, null, l_a, null);
      v_got2 := 'went through';
    exception when others then v_got2 := sqlerrm; end;
    case_name := 'a transfer waiting for approval takes no new line and no stock pinned to its lines, so what is approved is what was asked about';
    passed := coalesce(erp.document_state_code(t_add) = 'pending_approval'
              and v_got like 'CLOVEERP_TRANSFER_CHANGED_ONLY_AS_A_DRAFT%'
              and v_got2 like 'CLOVEERP_TRANSFER_CHANGED_ONLY_AS_A_DRAFT%'
              and (select sum(l.quantity) from erp.document_line l where l.document_id = t_add) = 5, false);
    detail := format('a new line: %s; stock pinned: %s', left(v_got, 90), left(v_got2, 90));
    return next;

    -- ── 14. And is not approved over lines changed since it was asked ──────
    v_fixture := 'a line changed behind the doors';
    t_edit := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 5))) ->> 'document_id')::uuid;
    update erp.document_line set quantity = 900 where tenant_id = r.tenant_id and document_id = t_edit;
    perform set_config('request.jwt.claims', json_build_object('sub', a_app)::text, true);
    v_got := erp_test.stock_state_try(t_edit, 'approve');
    select t.id into v_task
      from erp.approval_task t join erp.approval_request q on q.id = t.approval_request_id
     where q.tenant_id = r.tenant_id and q.object_id = t_edit and t.status = 'pending'
       and t.assignee_user_id = v_app limit 1;
    begin
      perform erp.decide_approval_task(v_task, true, 'looks fine');
      v_got2 := 'went through';
    exception when others then v_got2 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a_mov)::text, true);
    case_name := 'a transfer whose lines changed after its approval was asked for is not approved, on the document or under My approvals';
    passed := coalesce(v_got like 'CLOVEERP_DOCUMENT_CHANGED_SINCE_APPROVAL%'
              and v_got2 like 'CLOVEERP_DOCUMENT_CHANGED_SINCE_APPROVAL%'
              and erp.document_state_code(t_edit) = 'pending_approval', false);
    detail := format('on the document: %s; under My approvals: %s; stands %s', left(v_got, 90), left(v_got2, 90),
                     erp.document_state_code(t_edit));
    return next;

    -- ── 15. Decided under My approvals, it moves with the decision ─────────
    v_fixture := 'My approvals';
    t_mya := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 5))) ->> 'document_id')::uuid;
    t_myr := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 6))) ->> 'document_id')::uuid;
    perform set_config('request.jwt.claims', json_build_object('sub', a_app)::text, true);
    select t.id into v_task
      from erp.approval_task t join erp.approval_request q on q.id = t.approval_request_id
     where q.tenant_id = r.tenant_id and q.object_id = t_mya and t.status = 'pending'
       and t.assignee_user_id = v_app limit 1;
    perform erp.decide_approval_task(v_task, true, 'fine by me');
    select t.id into v_task
      from erp.approval_task t join erp.approval_request q on q.id = t.approval_request_id
     where q.tenant_id = r.tenant_id and q.object_id = t_myr and t.status = 'pending'
       and t.assignee_user_id = v_app limit 1;
    perform erp.decide_approval_task(v_task, false, 'too many at once');
    perform set_config('request.jwt.claims', json_build_object('sub', a_mov)::text, true);
    select string_agg(l.transition_code || coalesce('[' || (l.guard_data -> 'derived' ->> 'fact') || ']', ''), ',' order by l.id)
      into v_codes from erp.state_transition_log l where l.tenant_id = r.tenant_id and l.object_id = t_mya;
    select string_agg(l.transition_code, ',' order by l.id)
      into v_got from erp.state_transition_log l where l.tenant_id = r.tenant_id and l.object_id = t_myr;
    case_name := 'a transfer approved under My approvals is approved, and one rejected there goes back to draft, each with the decision and nobody pressing the document';
    passed := coalesce(erp.document_state_code(t_mya) = 'approved'
              and erp.document_state_code(t_myr) = 'draft'
              and v_codes = 'submit,approve[erp.approval_request]'
              and v_got = 'submit,reject'
              and (select l.reason from erp.state_transition_log l
                    where l.object_id = t_mya and l.transition_code = 'approve') = 'Approved under My approvals', false);
    detail := format('approved one %s by %s; rejected one %s by %s', erp.document_state_code(t_mya), coalesce(v_codes, 'nothing'),
                     erp.document_state_code(t_myr), coalesce(v_got, 'nothing'));
    return next;

    -- ── 16. Issued is the despatch's ────────────────────────────────────────
    v_fixture := 'issued by hand';
    v_got := erp_test.stock_state_try(t_small, 'issued');
    v_bad := erp_test.stock_state_menu_disagrees(t_small);
    perform erp.despatch_transfer(t_small);
    select l.guard_data -> 'derived' ->> 'fact' into v_got2
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_id = t_small and l.transition_code = 'issued';
    case_name := 'a transfer is not pressed to issued, which would strand it with nothing loaded, and its despatch takes issued as it loads';
    passed := coalesce(v_got like 'CLOVEERP_TRANSFER_LOADED_BY_ITS_DOOR%'
              and v_bad is null
              and erp.document_state_code(t_small) = 'in_transit'
              and v_got2 = 'erp.despatch_transfer', false);
    detail := format('pressed: %s; menu %s; despatched to %s, issued derived from %s', left(v_got, 80),
                     coalesce(v_bad, 'agrees'), erp.document_state_code(t_small), coalesce(v_got2, 'nothing'));
    return next;

    -- ── 17. A request still waiting asks somebody, whatever the type says ──
    v_fixture := 'a chain taken off the type';
    t_nochain := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 5))) ->> 'document_id')::uuid;
    begin
      update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
      update erp.document_type set approval_chain_code = null
       where tenant_id = r.tenant_id and code = 'transfer_order';
      update erp.environment set is_live = true where tenant_id = r.tenant_id and is_self;
      v_ok := erp.approval_asked_nobody(t_nochain);
      v_got := erp_test.stock_state_try(t_nochain, 'approve_within_threshold');
      raise exception 'CLOVEERP_SUITE_CHAIN_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_SUITE_CHAIN_UNDO' then v_got := sqlerrm; v_ok := null; end if;
    end;
    case_name := 'a transfer waiting on a request is not approved within its threshold even once its type names no chain';
    passed := coalesce(not v_ok and v_got like 'CLOVEERP_TRANSFER_AWAITS_APPROVAL%'
              and erp.document_state_code(t_nochain) = 'pending_approval', false);
    detail := format('asked nobody: %s; within the threshold: %s', coalesce(v_ok::text, 'unknown'), left(v_got, 90));
    return next;

    -- ── 18. Stock with no cost is not waved through ────────────────────────
    v_fixture := 'stock with no cost';
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'ZZ-U', 'Uncosted widget', v_uom, 'active') returning id into v_item2;
    t_nocost := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item2, 'quantity', 1))) ->> 'document_id')::uuid;
    select q.value_at_approval into v_q
      from erp.approval_request q where q.tenant_id = r.tenant_id and q.object_id = t_nocost;
    case_name := 'a transfer of stock with no cost at the despatching site waits for approval once a threshold is set, whatever it holds';
    passed := coalesce(erp.document_state_code(t_nocost) = 'pending_approval'
              and v_q = 9223372036854775807, false);
    detail := format('%s, valued %s', erp.document_state_code(t_nocost), coalesce(v_q::text, 'nothing'));
    return next;

    -- ── 19. The demonstration's trunk run takes version 2's route ──────────
    v_fixture := 'a demonstration';
    select * into rd from erp.provision_tenant(
      'zz-tos-demo-' || v_hex, 'Transfer order suite demonstration',
      'a@zz-tos-demo-' || v_hex || '.test', 'Demo Admin');
    update erp.environment set is_live = false where tenant_id = rd.tenant_id and is_self;
    perform set_config('request.jwt.claims', json_build_object('sub', a_demo)::text, true);
    perform erp.claim_invitation(rd.admin_token);
    perform erp.ensure_demo_configuration(rd.tenant_id, rd.admin_user_id);
    -- A week from a Monday a year ago, so it holds a Wednesday.
    v_from := (date_trunc('week', current_date - interval '12 months'))::date;
    perform erp.seed_demo_history(v_from, null, 1);
    perform erp.seed_demo_history(v_from + 5, null, 1);
    set constraints all immediate;
    select count(*),
           count(*) filter (where erp.document_state_code(d.id) = 'closed'
                              and exists (select 1 from erp.state_transition_log l
                                           where l.tenant_id = d.tenant_id and l.object_id = d.id
                                             and l.transition_code = 'approve_within_threshold')
                              and exists (select 1 from erp.state_transition_log l
                                           where l.tenant_id = d.tenant_id and l.object_id = d.id
                                             and l.transition_code = 'close'
                                             and l.guard_data -> 'derived' ->> 'fact' = 'erp.transfer_is_received_in_full')
                              and not exists (select 1 from erp.state_transition_log l
                                               where l.tenant_id = d.tenant_id and l.object_id = d.id
                                                 and l.transition_code = 'approved'))
      into v_n, v_n2
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = rd.tenant_id and dt.base_type_code = 'transfer_order';
    select coalesce(sum(b.quantity), 0) into v_q
      from erp.stock_balance b where b.tenant_id = rd.tenant_id and b.stock_status = 'in_transit';
    case_name := 'the demonstration raises its trunk run approved, loads it and books it in, and each one closes, with no click on an approval and nothing left on the road';
    passed := v_n >= 1 and v_n2 = v_n and v_q = 0;
    detail := format('%s transfer(s) from %s, %s closed by version 2''s route; %s in transit', v_n, v_from, v_n2, trim_scale(v_q));
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
  passed := not exists (select 1 from erp.tenant t where t.code in ('zz-tos-' || v_hex, 'zz-tos-demo-' || v_hex))
            and current_user = v_owner
            and coalesce(current_setting('erp.deriving_move', true), '') = '';
  detail := 'both organisations, their transfers, the chain proposed and the people rolled back';
  return next;
end;
$$;

revoke all on function erp_test.transfer_order_suite() from public, anon;

comment on function erp_test.transfer_order_suite() is
  'Version 2 of the transfer order''s lifecycle (20260928200000): installed and taken as an upgrade, '
  'version 1 in flight, no threshold and a threshold, a permission on every move, the receiving site''s '
  'close, the derived close, no discrepancy, no amendment or new line once submitted, no approval over '
  'changed lines, My approvals, issued by its despatch, stock with no cost, and the demonstration.';

create or replace function erp_test.assert_transfer_order_suite()
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
    from erp_test.transfer_order_suite() s;
  -- Failures first, so a suite that stopped part way says where.
  if v_failed > 0 then
    raise exception 'CLOVEERP_TRANSFER_ORDER_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A transfer order was approved, moved or closed other than its lifecycle says. Read the case that failed.';
  end if;
  if v_total <> 20 then
    raise exception 'CLOVEERP_TRANSFER_ORDER_SUITE_SHRANK: % case(s), expected 20; the fixture stopped %', v_total,
      coalesce(v_ended, 'nowhere')
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('transfer orders: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_transfer_order_suite() from public, anon;

comment on function erp_test.assert_transfer_order_suite() is
  'Version 2 of the transfer order''s lifecycle is approved by its value, asks a permission of every '
  'move and closes when its goods have arrived, and version 1 in flight moves as it did (20260928200000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B4. The words the transfers screen says for it
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). The Site transfers screen, true of either version of the transfer order''s lifecycle (20260928200000).'
  from (values
    ('Both sites must belong to the same company. Nothing moves until the order is approved, and a large one may need somebody else to approve it.')
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
