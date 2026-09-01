-- =============================================================================
-- Starter Content Packs — the base pack, part two: §5, §7, §8 and §9
--
-- §5's lifecycles, §7's policies and tolerances, §8's finance skeleton and §9's
-- operations content. All of it as change-set items on the same base pack, so
-- it arrives through promotion with a preview and a rollback.
--
-- Two scope decisions are stated where they bite, and both are collisions with
-- what is already built rather than choices:
--
--   SIX OF §5.1'S ELEVEN DOCUMENT LIFECYCLES ARE ALREADY CREATED by the module
--   installers. Shipping them again would promote a new state machine VERSION
--   over whatever the module configured — and a version whose states do not
--   include the one an in-flight document is sitting in strands that document.
--   The pack ships the fourteen nothing else creates, and
--   erp.lifecycle_coverage_report() names where an installed one differs from
--   §5.1's list rather than overwriting it.
--
--   §9.3'S SIXTEEN OUTPUT TEMPLATES HAVE NOWHERE TO GO. There is no document
--   or label template surface in this schema: erp.notification_template is for
--   messages, erp.code_template is for product codes, and neither renders a
--   delivery note. Sixteen items pointing at a table that does not exist would
--   be a pack that fails on application, so they are not here, and the gap is
--   recorded as an open decision rather than left to be rediscovered.
-- =============================================================================

-- ── §5 States and lifecycles ─────────────────────────────────────────────────
--
-- Each lifecycle is the section's own arrow chain, with the states after the
-- semicolon as exceptions. A terminal exception ends the object; a returning
-- one goes back to a named state, because "amended" and "held" and "recount"
-- are places you come back from and "cancelled" is not. Every exception is
-- reachable from every non-terminal state on the happy path — an exception you
-- can only reach from one place is not an exception.
--
-- erp.activate_state_machine_version() validates the graph on promotion, so a
-- lifecycle with an unreachable state or no way to finish fails the promotion
-- rather than shipping.

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, provenance, seq)
select 'base', 'state_machine', l.code,
       jsonb_build_object('code', l.code, 'object_type', l.object_type,
                          'name', l.name, 'states', l.states,
                          'transitions', l.transitions),
       l.why, 2000 + l.seq
  from (values
  ('works_order', 'document', 'Works order',
   $sm$[{"code":"planned","name":"Planned","is_initial":true,"is_terminal":false,"is_committed":false,"sort_order":10},{"code":"firmed","name":"Firmed","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":20},{"code":"released","name":"Released","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":30},{"code":"in_progress","name":"In progress","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":40},{"code":"completed","name":"Completed","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":50},{"code":"closed","name":"Closed","is_initial":false,"is_terminal":true,"is_committed":true,"sort_order":60},{"code":"held","name":"Held","is_initial":false,"is_terminal":false,"is_committed":false,"sort_order":500},{"code":"scrapped","name":"Scrapped","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":510},{"code":"cancelled","name":"Cancelled","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":520}]$sm$::jsonb,
   $sm$[{"code":"firmed","name":"Firmed","from":"planned","to":"firmed","sort_order":10},{"code":"released","name":"Released","from":"firmed","to":"released","sort_order":20},{"code":"in_progress","name":"In progress","from":"released","to":"in_progress","sort_order":30},{"code":"completed","name":"Completed","from":"in_progress","to":"completed","sort_order":40},{"code":"closed","name":"Closed","from":"completed","to":"closed","sort_order":50},{"code":"planned_to_held","name":"Held","from":"planned","to":"held","sort_order":500},{"code":"firmed_to_held","name":"Held","from":"firmed","to":"held","sort_order":500},{"code":"released_to_held","name":"Held","from":"released","to":"held","sort_order":500},{"code":"in_progress_to_held","name":"Held","from":"in_progress","to":"held","sort_order":500},{"code":"completed_to_held","name":"Held","from":"completed","to":"held","sort_order":500},{"code":"held_to_released","name":"Resume at released","from":"held","to":"released","sort_order":505},{"code":"planned_to_scrapped","name":"Scrapped","from":"planned","to":"scrapped","sort_order":510},{"code":"firmed_to_scrapped","name":"Scrapped","from":"firmed","to":"scrapped","sort_order":510},{"code":"released_to_scrapped","name":"Scrapped","from":"released","to":"scrapped","sort_order":510},{"code":"in_progress_to_scrapped","name":"Scrapped","from":"in_progress","to":"scrapped","sort_order":510},{"code":"completed_to_scrapped","name":"Scrapped","from":"completed","to":"scrapped","sort_order":510},{"code":"planned_to_cancelled","name":"Cancelled","from":"planned","to":"cancelled","sort_order":520},{"code":"firmed_to_cancelled","name":"Cancelled","from":"firmed","to":"cancelled","sort_order":520},{"code":"released_to_cancelled","name":"Cancelled","from":"released","to":"cancelled","sort_order":520},{"code":"in_progress_to_cancelled","name":"Cancelled","from":"in_progress","to":"cancelled","sort_order":520},{"code":"completed_to_cancelled","name":"Cancelled","from":"completed","to":"cancelled","sort_order":520}]$sm$::jsonb,
   70,
   'Starter Content Packs §5.1, works order. Terminology §3 keeps works order, not work order or production order.'),
  ('transfer_order', 'document', 'Transfer order',
   $sm$[{"code":"draft","name":"Draft","is_initial":true,"is_terminal":false,"is_committed":false,"sort_order":10},{"code":"approved","name":"Approved","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":20},{"code":"issued","name":"Issued","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":30},{"code":"in_transit","name":"In transit","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":40},{"code":"received","name":"Received","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":50},{"code":"closed","name":"Closed","is_initial":false,"is_terminal":true,"is_committed":true,"sort_order":60},{"code":"discrepancy","name":"Discrepancy","is_initial":false,"is_terminal":false,"is_committed":false,"sort_order":500},{"code":"cancelled","name":"Cancelled","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":510}]$sm$::jsonb,
   $sm$[{"code":"approved","name":"Approved","from":"draft","to":"approved","sort_order":10},{"code":"issued","name":"Issued","from":"approved","to":"issued","sort_order":20},{"code":"in_transit","name":"In transit","from":"issued","to":"in_transit","sort_order":30},{"code":"received","name":"Received","from":"in_transit","to":"received","sort_order":40},{"code":"closed","name":"Closed","from":"received","to":"closed","sort_order":50},{"code":"draft_to_discrepancy","name":"Discrepancy","from":"draft","to":"discrepancy","sort_order":500},{"code":"approved_to_discrepancy","name":"Discrepancy","from":"approved","to":"discrepancy","sort_order":500},{"code":"issued_to_discrepancy","name":"Discrepancy","from":"issued","to":"discrepancy","sort_order":500},{"code":"in_transit_to_discrepancy","name":"Discrepancy","from":"in_transit","to":"discrepancy","sort_order":500},{"code":"received_to_discrepancy","name":"Discrepancy","from":"received","to":"discrepancy","sort_order":500},{"code":"discrepancy_to_received","name":"Resume at received","from":"discrepancy","to":"received","sort_order":505},{"code":"draft_to_cancelled","name":"Cancelled","from":"draft","to":"cancelled","sort_order":510},{"code":"approved_to_cancelled","name":"Cancelled","from":"approved","to":"cancelled","sort_order":510},{"code":"issued_to_cancelled","name":"Cancelled","from":"issued","to":"cancelled","sort_order":510},{"code":"in_transit_to_cancelled","name":"Cancelled","from":"in_transit","to":"cancelled","sort_order":510},{"code":"received_to_cancelled","name":"Cancelled","from":"received","to":"cancelled","sort_order":510}]$sm$::jsonb,
   80,
   'Starter Content Packs §5.1, transfer order.'),
  ('count', 'document', 'Count',
   $sm$[{"code":"scheduled","name":"Scheduled","is_initial":true,"is_terminal":false,"is_committed":false,"sort_order":10},{"code":"in_progress","name":"In progress","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":20},{"code":"counted","name":"Counted","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":30},{"code":"under_review","name":"Under review","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":40},{"code":"approved","name":"Approved","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":50},{"code":"posted","name":"Posted","is_initial":false,"is_terminal":true,"is_committed":true,"sort_order":60},{"code":"recount","name":"Recount","is_initial":false,"is_terminal":false,"is_committed":false,"sort_order":500},{"code":"cancelled","name":"Cancelled","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":510}]$sm$::jsonb,
   $sm$[{"code":"in_progress","name":"In progress","from":"scheduled","to":"in_progress","sort_order":10},{"code":"counted","name":"Counted","from":"in_progress","to":"counted","sort_order":20},{"code":"under_review","name":"Under review","from":"counted","to":"under_review","sort_order":30},{"code":"approved","name":"Approved","from":"under_review","to":"approved","sort_order":40},{"code":"posted","name":"Posted","from":"approved","to":"posted","sort_order":50},{"code":"scheduled_to_recount","name":"Recount","from":"scheduled","to":"recount","sort_order":500},{"code":"in_progress_to_recount","name":"Recount","from":"in_progress","to":"recount","sort_order":500},{"code":"counted_to_recount","name":"Recount","from":"counted","to":"recount","sort_order":500},{"code":"under_review_to_recount","name":"Recount","from":"under_review","to":"recount","sort_order":500},{"code":"approved_to_recount","name":"Recount","from":"approved","to":"recount","sort_order":500},{"code":"recount_to_in_progress","name":"Resume at in progress","from":"recount","to":"in_progress","sort_order":505},{"code":"scheduled_to_cancelled","name":"Cancelled","from":"scheduled","to":"cancelled","sort_order":510},{"code":"in_progress_to_cancelled","name":"Cancelled","from":"in_progress","to":"cancelled","sort_order":510},{"code":"counted_to_cancelled","name":"Cancelled","from":"counted","to":"cancelled","sort_order":510},{"code":"under_review_to_cancelled","name":"Cancelled","from":"under_review","to":"cancelled","sort_order":510},{"code":"approved_to_cancelled","name":"Cancelled","from":"approved","to":"cancelled","sort_order":510}]$sm$::jsonb,
   90,
   'Starter Content Packs §5.1, count. Terminology §2 distinguishes the cycle count programme from the wall-to-wall stocktake; both use this lifecycle.'),
  ('return', 'document', 'Return',
   $sm$[{"code":"requested","name":"Requested","is_initial":true,"is_terminal":false,"is_committed":false,"sort_order":10},{"code":"authorised","name":"Authorised","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":20},{"code":"received","name":"Received","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":30},{"code":"inspected","name":"Inspected","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":40},{"code":"dispositioned","name":"Dispositioned","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":50},{"code":"closed","name":"Closed","is_initial":false,"is_terminal":true,"is_committed":true,"sort_order":60},{"code":"refused","name":"Refused","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":500}]$sm$::jsonb,
   $sm$[{"code":"authorised","name":"Authorised","from":"requested","to":"authorised","sort_order":10},{"code":"received","name":"Received","from":"authorised","to":"received","sort_order":20},{"code":"inspected","name":"Inspected","from":"received","to":"inspected","sort_order":30},{"code":"dispositioned","name":"Dispositioned","from":"inspected","to":"dispositioned","sort_order":40},{"code":"closed","name":"Closed","from":"dispositioned","to":"closed","sort_order":50},{"code":"requested_to_refused","name":"Refused","from":"requested","to":"refused","sort_order":500},{"code":"authorised_to_refused","name":"Refused","from":"authorised","to":"refused","sort_order":500},{"code":"received_to_refused","name":"Refused","from":"received","to":"refused","sort_order":500},{"code":"inspected_to_refused","name":"Refused","from":"inspected","to":"refused","sort_order":500},{"code":"dispositioned_to_refused","name":"Refused","from":"dispositioned","to":"refused","sort_order":500}]$sm$::jsonb,
   100,
   'Starter Content Packs §5.1, return.'),
  ('supplier_invoice', 'document', 'Supplier invoice',
   $sm$[{"code":"received","name":"Received","is_initial":true,"is_terminal":false,"is_committed":false,"sort_order":10},{"code":"matched","name":"Matched","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":20},{"code":"approved","name":"Approved","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":30},{"code":"posted","name":"Posted","is_initial":false,"is_terminal":true,"is_committed":true,"sort_order":40},{"code":"disputed","name":"Disputed","is_initial":false,"is_terminal":false,"is_committed":false,"sort_order":500},{"code":"rejected","name":"Rejected","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":510}]$sm$::jsonb,
   $sm$[{"code":"matched","name":"Matched","from":"received","to":"matched","sort_order":10},{"code":"approved","name":"Approved","from":"matched","to":"approved","sort_order":20},{"code":"posted","name":"Posted","from":"approved","to":"posted","sort_order":30},{"code":"received_to_disputed","name":"Disputed","from":"received","to":"disputed","sort_order":500},{"code":"matched_to_disputed","name":"Disputed","from":"matched","to":"disputed","sort_order":500},{"code":"approved_to_disputed","name":"Disputed","from":"approved","to":"disputed","sort_order":500},{"code":"disputed_to_matched","name":"Resume at matched","from":"disputed","to":"matched","sort_order":505},{"code":"received_to_rejected","name":"Rejected","from":"received","to":"rejected","sort_order":510},{"code":"matched_to_rejected","name":"Rejected","from":"matched","to":"rejected","sort_order":510},{"code":"approved_to_rejected","name":"Rejected","from":"approved","to":"rejected","sort_order":510}]$sm$::jsonb,
   110,
   'Starter Content Packs §5.1, supplier invoice.'),
  ('batch', 'batch', 'Batch',
   $sm$[{"code":"created","name":"Created","is_initial":true,"is_terminal":false,"is_committed":false,"sort_order":10},{"code":"quarantine","name":"Quarantine","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":20},{"code":"under_test","name":"Under test","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":30},{"code":"released","name":"Released","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":40},{"code":"in_use","name":"In use","is_initial":false,"is_terminal":true,"is_committed":true,"sort_order":50},{"code":"blocked","name":"Blocked","is_initial":false,"is_terminal":false,"is_committed":false,"sort_order":500},{"code":"recalled","name":"Recalled","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":510},{"code":"expired","name":"Expired","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":520},{"code":"consumed","name":"Consumed","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":530},{"code":"rejected","name":"Rejected","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":540},{"code":"disposed","name":"Disposed","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":550}]$sm$::jsonb,
   $sm$[{"code":"quarantine","name":"Quarantine","from":"created","to":"quarantine","sort_order":10},{"code":"under_test","name":"Under test","from":"quarantine","to":"under_test","sort_order":20},{"code":"released","name":"Released","from":"under_test","to":"released","sort_order":30},{"code":"in_use","name":"In use","from":"released","to":"in_use","sort_order":40},{"code":"created_to_blocked","name":"Blocked","from":"created","to":"blocked","sort_order":500},{"code":"quarantine_to_blocked","name":"Blocked","from":"quarantine","to":"blocked","sort_order":500},{"code":"under_test_to_blocked","name":"Blocked","from":"under_test","to":"blocked","sort_order":500},{"code":"released_to_blocked","name":"Blocked","from":"released","to":"blocked","sort_order":500},{"code":"blocked_to_quarantine","name":"Resume at quarantine","from":"blocked","to":"quarantine","sort_order":505},{"code":"created_to_recalled","name":"Recalled","from":"created","to":"recalled","sort_order":510},{"code":"quarantine_to_recalled","name":"Recalled","from":"quarantine","to":"recalled","sort_order":510},{"code":"under_test_to_recalled","name":"Recalled","from":"under_test","to":"recalled","sort_order":510},{"code":"released_to_recalled","name":"Recalled","from":"released","to":"recalled","sort_order":510},{"code":"created_to_expired","name":"Expired","from":"created","to":"expired","sort_order":520},{"code":"quarantine_to_expired","name":"Expired","from":"quarantine","to":"expired","sort_order":520},{"code":"under_test_to_expired","name":"Expired","from":"under_test","to":"expired","sort_order":520},{"code":"released_to_expired","name":"Expired","from":"released","to":"expired","sort_order":520},{"code":"created_to_consumed","name":"Consumed","from":"created","to":"consumed","sort_order":530},{"code":"quarantine_to_consumed","name":"Consumed","from":"quarantine","to":"consumed","sort_order":530},{"code":"under_test_to_consumed","name":"Consumed","from":"under_test","to":"consumed","sort_order":530},{"code":"released_to_consumed","name":"Consumed","from":"released","to":"consumed","sort_order":530},{"code":"created_to_rejected","name":"Rejected","from":"created","to":"rejected","sort_order":540},{"code":"quarantine_to_rejected","name":"Rejected","from":"quarantine","to":"rejected","sort_order":540},{"code":"under_test_to_rejected","name":"Rejected","from":"under_test","to":"rejected","sort_order":540},{"code":"released_to_rejected","name":"Rejected","from":"released","to":"rejected","sort_order":540},{"code":"created_to_disposed","name":"Disposed","from":"created","to":"disposed","sort_order":550},{"code":"quarantine_to_disposed","name":"Disposed","from":"quarantine","to":"disposed","sort_order":550},{"code":"under_test_to_disposed","name":"Disposed","from":"under_test","to":"disposed","sort_order":550},{"code":"released_to_disposed","name":"Disposed","from":"released","to":"disposed","sort_order":550}]$sm$::jsonb,
   200,
   'Starter Content Packs §5.2. Release, unblock and expiry extension require named authority, so those transitions carry quality.release_batch.'),
  ('container', 'container', 'Handling unit',
   $sm$[{"code":"created","name":"Created","is_initial":true,"is_terminal":false,"is_committed":false,"sort_order":10},{"code":"filled","name":"Filled","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":20},{"code":"sealed","name":"Sealed","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":30},{"code":"in_storage","name":"In storage","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":40},{"code":"picked","name":"Picked","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":50},{"code":"despatched","name":"Despatched","is_initial":false,"is_terminal":true,"is_committed":true,"sort_order":60},{"code":"broken_down","name":"Broken down","is_initial":false,"is_terminal":false,"is_committed":false,"sort_order":500},{"code":"returned","name":"Returned","is_initial":false,"is_terminal":false,"is_committed":false,"sort_order":510},{"code":"damaged","name":"Damaged","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":520}]$sm$::jsonb,
   $sm$[{"code":"filled","name":"Filled","from":"created","to":"filled","sort_order":10},{"code":"sealed","name":"Sealed","from":"filled","to":"sealed","sort_order":20},{"code":"in_storage","name":"In storage","from":"sealed","to":"in_storage","sort_order":30},{"code":"picked","name":"Picked","from":"in_storage","to":"picked","sort_order":40},{"code":"despatched","name":"Despatched","from":"picked","to":"despatched","sort_order":50},{"code":"created_to_broken_down","name":"Broken down","from":"created","to":"broken_down","sort_order":500},{"code":"filled_to_broken_down","name":"Broken down","from":"filled","to":"broken_down","sort_order":500},{"code":"sealed_to_broken_down","name":"Broken down","from":"sealed","to":"broken_down","sort_order":500},{"code":"in_storage_to_broken_down","name":"Broken down","from":"in_storage","to":"broken_down","sort_order":500},{"code":"picked_to_broken_down","name":"Broken down","from":"picked","to":"broken_down","sort_order":500},{"code":"broken_down_to_created","name":"Resume at created","from":"broken_down","to":"created","sort_order":505},{"code":"created_to_returned","name":"Returned","from":"created","to":"returned","sort_order":510},{"code":"filled_to_returned","name":"Returned","from":"filled","to":"returned","sort_order":510},{"code":"sealed_to_returned","name":"Returned","from":"sealed","to":"returned","sort_order":510},{"code":"in_storage_to_returned","name":"Returned","from":"in_storage","to":"returned","sort_order":510},{"code":"picked_to_returned","name":"Returned","from":"picked","to":"returned","sort_order":510},{"code":"returned_to_in_storage","name":"Resume at in storage","from":"returned","to":"in_storage","sort_order":515},{"code":"created_to_damaged","name":"Damaged","from":"created","to":"damaged","sort_order":520},{"code":"filled_to_damaged","name":"Damaged","from":"filled","to":"damaged","sort_order":520},{"code":"sealed_to_damaged","name":"Damaged","from":"sealed","to":"damaged","sort_order":520},{"code":"in_storage_to_damaged","name":"Damaged","from":"in_storage","to":"damaged","sort_order":520},{"code":"picked_to_damaged","name":"Damaged","from":"picked","to":"damaged","sort_order":520}]$sm$::jsonb,
   210,
   'Starter Content Packs §5.3. Terminology §2 calls this a handling unit on the product surface; container stays in the model.'),
  ('allocation', 'allocation', 'Allocation',
   $sm$[{"code":"requested","name":"Requested","is_initial":true,"is_terminal":false,"is_committed":false,"sort_order":10},{"code":"global_allocated","name":"Global allocated","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":20},{"code":"detail_allocated","name":"Detail allocated","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":30},{"code":"picked","name":"Picked","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":40},{"code":"consumed","name":"Consumed","is_initial":false,"is_terminal":true,"is_committed":true,"sort_order":50},{"code":"failed","name":"Failed","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":500},{"code":"released","name":"Released","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":510},{"code":"expired","name":"Expired","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":520},{"code":"overridden","name":"Overridden","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":530}]$sm$::jsonb,
   $sm$[{"code":"global_allocated","name":"Global allocated","from":"requested","to":"global_allocated","sort_order":10},{"code":"detail_allocated","name":"Detail allocated","from":"global_allocated","to":"detail_allocated","sort_order":20},{"code":"picked","name":"Picked","from":"detail_allocated","to":"picked","sort_order":30},{"code":"consumed","name":"Consumed","from":"picked","to":"consumed","sort_order":40},{"code":"requested_to_failed","name":"Failed","from":"requested","to":"failed","sort_order":500},{"code":"global_allocated_to_failed","name":"Failed","from":"global_allocated","to":"failed","sort_order":500},{"code":"detail_allocated_to_failed","name":"Failed","from":"detail_allocated","to":"failed","sort_order":500},{"code":"picked_to_failed","name":"Failed","from":"picked","to":"failed","sort_order":500},{"code":"requested_to_released","name":"Released","from":"requested","to":"released","sort_order":510},{"code":"global_allocated_to_released","name":"Released","from":"global_allocated","to":"released","sort_order":510},{"code":"detail_allocated_to_released","name":"Released","from":"detail_allocated","to":"released","sort_order":510},{"code":"picked_to_released","name":"Released","from":"picked","to":"released","sort_order":510},{"code":"requested_to_expired","name":"Expired","from":"requested","to":"expired","sort_order":520},{"code":"global_allocated_to_expired","name":"Expired","from":"global_allocated","to":"expired","sort_order":520},{"code":"detail_allocated_to_expired","name":"Expired","from":"detail_allocated","to":"expired","sort_order":520},{"code":"picked_to_expired","name":"Expired","from":"picked","to":"expired","sort_order":520},{"code":"requested_to_overridden","name":"Overridden","from":"requested","to":"overridden","sort_order":530},{"code":"global_allocated_to_overridden","name":"Overridden","from":"global_allocated","to":"overridden","sort_order":530},{"code":"detail_allocated_to_overridden","name":"Overridden","from":"detail_allocated","to":"overridden","sort_order":530},{"code":"picked_to_overridden","name":"Overridden","from":"picked","to":"overridden","sort_order":530}]$sm$::jsonb,
   220,
   'Starter Content Packs §5.4. Terminology §3 keeps global allocation and detailed allocation: every person configuring this already knows them.'),
  ('planned_order', 'planned_order', 'Planned order',
   $sm$[{"code":"proposed","name":"Proposed","is_initial":true,"is_terminal":false,"is_committed":false,"sort_order":10},{"code":"reviewed","name":"Reviewed","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":20},{"code":"firmed","name":"Firmed","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":30},{"code":"released","name":"Released","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":40},{"code":"converted","name":"Converted","is_initial":false,"is_terminal":true,"is_committed":true,"sort_order":50},{"code":"rejected","name":"Rejected","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":500},{"code":"superseded","name":"Superseded","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":510},{"code":"cancelled","name":"Cancelled","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":520}]$sm$::jsonb,
   $sm$[{"code":"reviewed","name":"Reviewed","from":"proposed","to":"reviewed","sort_order":10},{"code":"firmed","name":"Firmed","from":"reviewed","to":"firmed","sort_order":20},{"code":"released","name":"Released","from":"firmed","to":"released","sort_order":30},{"code":"converted","name":"Converted","from":"released","to":"converted","sort_order":40},{"code":"proposed_to_rejected","name":"Rejected","from":"proposed","to":"rejected","sort_order":500},{"code":"reviewed_to_rejected","name":"Rejected","from":"reviewed","to":"rejected","sort_order":500},{"code":"firmed_to_rejected","name":"Rejected","from":"firmed","to":"rejected","sort_order":500},{"code":"released_to_rejected","name":"Rejected","from":"released","to":"rejected","sort_order":500},{"code":"proposed_to_superseded","name":"Superseded","from":"proposed","to":"superseded","sort_order":510},{"code":"reviewed_to_superseded","name":"Superseded","from":"reviewed","to":"superseded","sort_order":510},{"code":"firmed_to_superseded","name":"Superseded","from":"firmed","to":"superseded","sort_order":510},{"code":"released_to_superseded","name":"Superseded","from":"released","to":"superseded","sort_order":510},{"code":"proposed_to_cancelled","name":"Cancelled","from":"proposed","to":"cancelled","sort_order":520},{"code":"reviewed_to_cancelled","name":"Cancelled","from":"reviewed","to":"cancelled","sort_order":520},{"code":"firmed_to_cancelled","name":"Cancelled","from":"firmed","to":"cancelled","sort_order":520},{"code":"released_to_cancelled","name":"Cancelled","from":"released","to":"cancelled","sort_order":520}]$sm$::jsonb,
   230,
   'Starter Content Packs §5.5.'),
  ('inspection', 'inspection', 'Inspection',
   $sm$[{"code":"raised","name":"Raised","is_initial":true,"is_terminal":false,"is_committed":false,"sort_order":10},{"code":"sampled","name":"Sampled","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":20},{"code":"in_test","name":"In test","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":30},{"code":"complete","name":"Complete","is_initial":false,"is_terminal":true,"is_committed":true,"sort_order":40},{"code":"cancelled","name":"Cancelled","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":500}]$sm$::jsonb,
   $sm$[{"code":"sampled","name":"Sampled","from":"raised","to":"sampled","sort_order":10},{"code":"in_test","name":"In test","from":"sampled","to":"in_test","sort_order":20},{"code":"complete","name":"Complete","from":"in_test","to":"complete","sort_order":30},{"code":"raised_to_cancelled","name":"Cancelled","from":"raised","to":"cancelled","sort_order":500},{"code":"sampled_to_cancelled","name":"Cancelled","from":"sampled","to":"cancelled","sort_order":500},{"code":"in_test_to_cancelled","name":"Cancelled","from":"in_test","to":"cancelled","sort_order":500}]$sm$::jsonb,
   240,
   'Starter Content Packs §5.6, inspection.'),
  ('disposition', 'disposition', 'Disposition',
   $sm$[{"code":"pending","name":"Pending","is_initial":true,"is_terminal":false,"is_committed":false,"sort_order":10},{"code":"accepted","name":"Accepted","is_initial":false,"is_terminal":true,"is_committed":true,"sort_order":20},{"code":"accepted_under_concession","name":"Accepted under concession","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":500},{"code":"rejected","name":"Rejected","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":510},{"code":"returned","name":"Returned","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":520},{"code":"destroyed","name":"Destroyed","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":530}]$sm$::jsonb,
   $sm$[{"code":"accepted","name":"Accepted","from":"pending","to":"accepted","sort_order":10},{"code":"pending_to_accepted_under_concession","name":"Accepted under concession","from":"pending","to":"accepted_under_concession","sort_order":500},{"code":"pending_to_rejected","name":"Rejected","from":"pending","to":"rejected","sort_order":510},{"code":"pending_to_returned","name":"Returned","from":"pending","to":"returned","sort_order":520},{"code":"pending_to_destroyed","name":"Destroyed","from":"pending","to":"destroyed","sort_order":530}]$sm$::jsonb,
   250,
   'Starter Content Packs §5.6, disposition. The section lists five outcomes after pending and they are alternatives rather than a sequence, so four are terminal branches off pending and accepted is the happy path.'),
  ('quality_event', 'quality_event', 'Quality event',
   $sm$[{"code":"raised","name":"Raised","is_initial":true,"is_terminal":false,"is_committed":false,"sort_order":10},{"code":"investigating","name":"Investigating","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":20},{"code":"root_cause_identified","name":"Root cause identified","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":30},{"code":"action_assigned","name":"Action assigned","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":40},{"code":"verifying","name":"Verifying","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":50},{"code":"closed","name":"Closed","is_initial":false,"is_terminal":true,"is_committed":true,"sort_order":60},{"code":"escalated","name":"Escalated","is_initial":false,"is_terminal":false,"is_committed":false,"sort_order":500}]$sm$::jsonb,
   $sm$[{"code":"investigating","name":"Investigating","from":"raised","to":"investigating","sort_order":10},{"code":"root_cause_identified","name":"Root cause identified","from":"investigating","to":"root_cause_identified","sort_order":20},{"code":"action_assigned","name":"Action assigned","from":"root_cause_identified","to":"action_assigned","sort_order":30},{"code":"verifying","name":"Verifying","from":"action_assigned","to":"verifying","sort_order":40},{"code":"closed","name":"Closed","from":"verifying","to":"closed","sort_order":50},{"code":"raised_to_escalated","name":"Escalated","from":"raised","to":"escalated","sort_order":500},{"code":"investigating_to_escalated","name":"Escalated","from":"investigating","to":"escalated","sort_order":500},{"code":"root_cause_identified_to_escalated","name":"Escalated","from":"root_cause_identified","to":"escalated","sort_order":500},{"code":"action_assigned_to_escalated","name":"Escalated","from":"action_assigned","to":"escalated","sort_order":500},{"code":"verifying_to_escalated","name":"Escalated","from":"verifying","to":"escalated","sort_order":500},{"code":"escalated_to_investigating","name":"Resume at investigating","from":"escalated","to":"investigating","sort_order":505}]$sm$::jsonb,
   260,
   'Starter Content Packs §5.6, quality event.'),
  ('recall', 'recall', 'Recall',
   $sm$[{"code":"initiated","name":"Initiated","is_initial":true,"is_terminal":false,"is_committed":false,"sort_order":10},{"code":"scoped","name":"Scoped","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":20},{"code":"notifying","name":"Notifying","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":30},{"code":"recovering","name":"Recovering","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":40},{"code":"reconciling","name":"Reconciling","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":50},{"code":"closed","name":"Closed","is_initial":false,"is_terminal":true,"is_committed":true,"sort_order":60}]$sm$::jsonb,
   $sm$[{"code":"scoped","name":"Scoped","from":"initiated","to":"scoped","sort_order":10},{"code":"notifying","name":"Notifying","from":"scoped","to":"notifying","sort_order":20},{"code":"recovering","name":"Recovering","from":"notifying","to":"recovering","sort_order":30},{"code":"reconciling","name":"Reconciling","from":"recovering","to":"reconciling","sort_order":40},{"code":"closed","name":"Closed","from":"reconciling","to":"closed","sort_order":50}]$sm$::jsonb,
   270,
   'Starter Content Packs §5.6, recall. No exception states: §5.6 lists none, and a recall that can be cancelled is not a regulatory clock.'),
  ('command', 'command', 'Command',
   $sm$[{"code":"requested","name":"Requested","is_initial":true,"is_terminal":false,"is_committed":false,"sort_order":10},{"code":"approved","name":"Approved","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":20},{"code":"dispatched","name":"Dispatched","is_initial":false,"is_terminal":false,"is_committed":true,"sort_order":30},{"code":"confirmed","name":"Confirmed","is_initial":false,"is_terminal":true,"is_committed":true,"sort_order":40},{"code":"failed","name":"Failed","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":500},{"code":"ambiguous","name":"Ambiguous","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":510},{"code":"compensated","name":"Compensated","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":520},{"code":"abandoned","name":"Abandoned","is_initial":false,"is_terminal":true,"is_committed":false,"sort_order":530}]$sm$::jsonb,
   $sm$[{"code":"approved","name":"Approved","from":"requested","to":"approved","sort_order":10},{"code":"dispatched","name":"Dispatched","from":"approved","to":"dispatched","sort_order":20},{"code":"confirmed","name":"Confirmed","from":"dispatched","to":"confirmed","sort_order":30},{"code":"requested_to_failed","name":"Failed","from":"requested","to":"failed","sort_order":500},{"code":"approved_to_failed","name":"Failed","from":"approved","to":"failed","sort_order":500},{"code":"dispatched_to_failed","name":"Failed","from":"dispatched","to":"failed","sort_order":500},{"code":"requested_to_ambiguous","name":"Ambiguous","from":"requested","to":"ambiguous","sort_order":510},{"code":"approved_to_ambiguous","name":"Ambiguous","from":"approved","to":"ambiguous","sort_order":510},{"code":"dispatched_to_ambiguous","name":"Ambiguous","from":"dispatched","to":"ambiguous","sort_order":510},{"code":"requested_to_compensated","name":"Compensated","from":"requested","to":"compensated","sort_order":520},{"code":"approved_to_compensated","name":"Compensated","from":"approved","to":"compensated","sort_order":520},{"code":"dispatched_to_compensated","name":"Compensated","from":"dispatched","to":"compensated","sort_order":520},{"code":"requested_to_abandoned","name":"Abandoned","from":"requested","to":"abandoned","sort_order":530},{"code":"approved_to_abandoned","name":"Abandoned","from":"approved","to":"abandoned","sort_order":530},{"code":"dispatched_to_abandoned","name":"Abandoned","from":"dispatched","to":"abandoned","sort_order":530}]$sm$::jsonb,
   280,
   'Starter Content Packs §5.7. The ambiguous state exists deliberately: an external write whose outcome is unknown is a distinct condition needing reconciliation, not a failure to retry blindly.')
  ) l(code, object_type, name, states, transitions, seq, why)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, provenance = excluded.provenance, seq = excluded.seq;

-- ── §7 Policies and tolerances ───────────────────────────────────────────────
--
-- "The values every ERP needs on day one, which otherwise get invented ad hoc
-- by whoever hits the screen first. Conservative defaults, all switchable."
--
-- Six of the thirteen have a table of their own — receipt tolerance, match
-- tolerance, count variance, costing method, escalation timers (on the
-- approval band) and re-approval tolerance (likewise). The other seven have
-- nowhere to be, so they arrive as config types: erp_ref.config_type is the
-- product's own mechanism for a named, schema-validated, scoped setting, and
-- it held exactly one row before this. Each carries a JSON Schema, so a value
-- outside the enum is refused at the door rather than discovered by a rule
-- that quietly does nothing.

insert into erp_ref.config_type
  (code, domain, module_code, name_key, description, value_schema,
   max_scope_level, is_singleton, default_value) values
  ('stock.shelf_life_minimum', 'threshold', 'inventory',
   'config.stock.shelf_life_minimum',
   'The remaining shelf life a batch must have to be received, transferred or '
   'despatched, as a percentage of its total life. Customer-specific overrides '
   'are permitted and sit on the customer, not here.',
   jsonb_build_object('type','object','additionalProperties',false,
     'properties', jsonb_build_object(
       'on_receipt_pct', jsonb_build_object('type','number','minimum',0,'maximum',100),
       'on_transfer_pct', jsonb_build_object('type','number','minimum',0,'maximum',100),
       'on_despatch_pct', jsonb_build_object('type','number','minimum',0,'maximum',100))),
   'site', true,
   jsonb_build_object('on_receipt_pct', 75, 'on_transfer_pct', 50, 'on_despatch_pct', 33)),

  ('stock.allocation_policy', 'policy', 'inventory',
   'config.stock.allocation_policy',
   'How allocation chooses between batches, and whether an order may be split '
   'across them.',
   jsonb_build_object('type','object','additionalProperties',false,
     'properties', jsonb_build_object(
       'expiry_controlled', jsonb_build_object('type','string','enum',
         jsonb_build_array('fefo','fifo','lifo')),
       'default', jsonb_build_object('type','string','enum',
         jsonb_build_array('fefo','fifo','lifo')),
       'single_batch_per_order', jsonb_build_object('type','boolean'),
       'prefer_nearest_location', jsonb_build_object('type','boolean'))),
   'site', true,
   jsonb_build_object('expiry_controlled','fefo','default','fifo',
                      'single_batch_per_order', false,
                      'prefer_nearest_location', true)),

  ('stock.reservation_ageing', 'threshold', 'inventory',
   'config.stock.reservation_ageing',
   'How long an unconsumed detailed allocation holds before returning to '
   'available, and how long staged stock waits in a marshalling area before '
   'returning to bulk.',
   jsonb_build_object('type','object','additionalProperties',false,
     'properties', jsonb_build_object(
       'detailed_allocation_hours', jsonb_build_object('type','integer','minimum',1),
       'marshalling_area_hours', jsonb_build_object('type','integer','minimum',1))),
   'site', true,
   jsonb_build_object('detailed_allocation_hours', 24, 'marshalling_area_hours', 72)),

  ('sales.credit_control', 'policy', 'sales',
   'config.sales.credit_control',
   'When a customer''s credit is checked, what happens at the limit, and how '
   'much overdue debt stops further supply.',
   jsonb_build_object('type','object','additionalProperties',false,
     'properties', jsonb_build_object(
       'check_at_capture', jsonb_build_object('type','boolean'),
       'block_at_limit', jsonb_build_object('type','boolean'),
       'tolerance_pct', jsonb_build_object('type','number','minimum',0,'maximum',100),
       'overdue_days_block', jsonb_build_object('type','integer','minimum',0))),
   'entity', true,
   jsonb_build_object('check_at_capture', true, 'block_at_limit', true,
                      'tolerance_pct', 5, 'overdue_days_block', 30)),

  ('sales.backorder_policy', 'policy', 'sales',
   'config.sales.backorder_policy',
   'What happens to an order line that cannot be filled: permit the backorder, '
   'refuse the line, or ship what there is. Per channel, because a trade '
   'customer and a consumer expect different answers.',
   jsonb_build_object('type','object','additionalProperties',false,
     'properties', jsonb_build_object(
       'default', jsonb_build_object('type','string','enum',
         jsonb_build_array('permit','refuse','partial_ship')),
       'by_channel', jsonb_build_object('type','object'))),
   'entity', true,
   jsonb_build_object('default','permit','by_channel', jsonb_build_object())),

  ('quality.quarantine_defaults', 'policy', 'quality',
   'config.quality.quarantine_defaults',
   'Which accounting codes land in quarantine on receipt, and how long stock '
   'may sit there before it is a finding.',
   jsonb_build_object('type','object','additionalProperties',false,
     'properties', jsonb_build_object(
       'posting_classes', jsonb_build_object('type','array',
         'items', jsonb_build_object('type','string')),
       'ageing_days_warn', jsonb_build_object('type','integer','minimum',1),
       'ageing_days_escalate', jsonb_build_object('type','integer','minimum',1))),
   'site', true,
   jsonb_build_object('posting_classes', jsonb_build_array('RAW','FG'),
                      'ageing_days_warn', 5, 'ageing_days_escalate', 10)),

  ('approval.reapproval_tolerance', 'threshold', 'administration',
   'config.approval.reapproval_tolerance',
   'How much an approved document may change before the approval is void and '
   'the chain runs again. Both a percentage and an absolute, because a small '
   'percentage of a large order is still a large sum.',
   jsonb_build_object('type','object','additionalProperties',false,
     'properties', jsonb_build_object(
       'value_change_pct', jsonb_build_object('type','number','minimum',0),
       'value_change_absolute_minor', jsonb_build_object('type','integer','minimum',0),
       'reapprove_on_supplier_change', jsonb_build_object('type','boolean'))),
   'entity', true,
   jsonb_build_object('value_change_pct', 10,
                      'value_change_absolute_minor', 50000,
                      'reapprove_on_supplier_change', true))
on conflict (code) do update set
  domain = excluded.domain, module_code = excluded.module_code,
  name_key = excluded.name_key, description = excluded.description,
  value_schema = excluded.value_schema, max_scope_level = excluded.max_scope_level,
  is_singleton = excluded.is_singleton, default_value = excluded.default_value;

-- Every config type names a resource key, and erp.assert_resource_coverage()
-- fails the build for one that resolves to nothing.
insert into erp_ref.resource (key, locale, value, description) values
  ('config.stock.shelf_life_minimum', 'en', 'Shelf-life minimums',
   'Starter Content Packs §7.'),
  ('config.stock.allocation_policy', 'en', 'Allocation policy',
   'Starter Content Packs §7.'),
  ('config.stock.reservation_ageing', 'en', 'Reservation and staging ageing',
   'Starter Content Packs §7.'),
  ('config.sales.credit_control', 'en', 'Credit control',
   'Starter Content Packs §7.'),
  ('config.sales.backorder_policy', 'en', 'Backorder policy',
   'Starter Content Packs §7.'),
  ('config.quality.quarantine_defaults', 'en', 'Quarantine defaults',
   'Starter Content Packs §7.'),
  ('config.approval.reapproval_tolerance', 'en', 'Re-approval tolerance',
   'Starter Content Packs §7.')
on conflict (key, locale) do update set
  value = excluded.value, description = excluded.description;

-- The seven config-type settings as pack items. Conservative, all switchable,
-- and none of them a decision — §11.4's decisions are the values a pack cannot
-- know, and a shelf-life minimum of 75% on receipt is a defensible default
-- that an organisation changes rather than a number only it can supply.

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, requires_capability, provenance, seq)
select 'base', 'config', ct.code || '||-|-',
       jsonb_build_object('config_type', ct.code, 'value', ct.default_value),
       c.cap,
       c.why, 3000 + c.seq
  from (values
    ('stock.shelf_life_minimum', 'expiry_control', 10,
     'Starter Content Packs §7, shelf-life minimums. 75/50/33 is the '
     'three-thirds convention common in food and pharmaceutical distribution: '
     'three quarters of life left on receipt, half on transfer, a third on '
     'despatch.'),
    ('stock.allocation_policy', null, 20,
     'Starter Content Packs §7: "FEFO default for expiry-controlled classes, '
     'FIFO for the rest; single-batch-per-order and nearest-location options". '
     'Single-batch is off because it fails orders that a split would fill.'),
    ('stock.reservation_ageing', null, 30,
     'Starter Content Packs §7, reservation and release-area ageing. 24 hours '
     'and 72 hours: a day for a picker to get to it, three for a marshalling '
     'area to clear over a weekend.'),
    ('sales.credit_control', 'credit_control', 40,
     'Starter Content Packs §7: "check at capture, block at limit, tolerance '
     'percentage, overdue-days block". 5% and 30 days are conventional UK '
     'trade terms.'),
    ('sales.backorder_policy', null, 50,
     'Starter Content Packs §7. Permit by default, because refusing is the '
     'harder-to-reverse choice and a channel that needs it says so.'),
    ('quality.quarantine_defaults', 'quality_inspection', 60,
     'Starter Content Packs §7. Raw material and finished goods quarantine on '
     'receipt; packaging and consumables do not, which is the usual split.'),
    ('approval.reapproval_tolerance', null, 70,
     'Starter Content Packs §7: "the value change that reopens an approved '
     'document". Both a percentage and an absolute, because ten per cent of a '
     'large order is still a large sum.')
  ) c(code, cap, seq, why)
  join erp_ref.config_type ct on ct.code = c.code
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, requires_capability = excluded.requires_capability,
  provenance = excluded.provenance, seq = excluded.seq;

-- The six with a table of their own.

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, requires_capability, provenance, seq)
values
  -- §7 names three behaviours on breach — "block, warn, or route to approval" —
  -- and erp.receipt_tolerance.over_action allows three different ones: accept,
  -- reject and quarantine. Neither set contains the other. Quarantine is the
  -- nearest thing to routing to approval, because the goods land somewhere
  -- they cannot be used until somebody decides; reject is block; accept is
  -- warn. The mapping is stated here rather than silently applied, and the
  -- collision is recorded below.
  ('base', 'receipt_tolerance', 'STANDARD',
   jsonb_build_object('code','STANDARD','name','Standard receipt tolerance',
     'over_pct', 5, 'under_pct', 5, 'over_action', 'quarantine'),
   null,
   'Starter Content Packs §7, receipt tolerance. 5% either way. An over-receipt '
   'above it quarantines rather than being rejected — refusing a delivery that '
   'is already on the bay helps nobody, and quarantine is this schema''s '
   'nearest equivalent to §7''s "route to approval".', 3100),
  ('base', 'receipt_tolerance', 'EXACT',
   jsonb_build_object('code','EXACT','name','No tolerance',
     'over_pct', 0, 'under_pct', 0, 'over_action', 'reject'),
   null,
   'Starter Content Packs §7, mapping "block" to reject. For accounting codes '
   'where any variance is a finding: controlled substances, high-value spares.', 3101),
  ('base', 'match_tolerance', 'STANDARD',
   jsonb_build_object('code','STANDARD','name','Standard three-way match',
     'quantity_pct', 0, 'price_pct', 2, 'price_absolute_minor', 500),
   null,
   'Starter Content Packs §7, three-way match. Quantity must match exactly — '
   'a quantity difference is a real difference — while price carries both a '
   'percentage and an absolute so that rounding on a small line does not open '
   'an exception nobody can close.', 3110),
  ('base', 'costing_policy', 'MANUFACTURED',
   jsonb_build_object('code','MANUFACTURED','name','Standard cost for manufactured',
     'method','standard','item_class','FG,SFG','variance_account','9100'),
   'production',
   'Starter Content Packs §7: "standard for manufactured, average for '
   'purchased, FIFO available".', 3120),
  ('base', 'costing_policy', 'PURCHASED',
   jsonb_build_object('code','PURCHASED','name','Average cost for purchased',
     'method','average','item_class','RAW,PACK,CONS,SPARE'),
   null,
   'Starter Content Packs §7, average for purchased.', 3121),
  ('base', 'count_programme', 'CYCLE_A',
   jsonb_build_object('code','CYCLE_A','name','Cycle count — high value',
     'kind','cycle','tolerance_pct', 1, 'tolerance_absolute', 1),
   'cycle_counting',
   'Starter Content Packs §7, count variance tolerance banded by value. The '
   'tight band for the lines worth counting often.', 3130),
  ('base', 'count_programme', 'CYCLE_C',
   jsonb_build_object('code','CYCLE_C','name','Cycle count — low value',
     'kind','cycle','tolerance_pct', 5, 'tolerance_absolute', 10),
   'cycle_counting',
   'Starter Content Packs §7. The loose band, so a five-pence washer does not '
   'raise the same exception as a pallet of finished goods.', 3131),
  ('base', 'count_programme', 'STOCKTAKE',
   jsonb_build_object('code','STOCKTAKE','name','Annual stocktake',
     'kind','annual','tolerance_pct', 0, 'tolerance_absolute', 0),
   null,
   'Terminology §2 distinguishes the wall-to-wall stocktake from the cycle '
   'count programme, and UK operations distinguish them clearly. Zero '
   'tolerance: an annual count is the number.', 3132),
  ('base', 'pricing_policy', 'STANDARD',
   jsonb_build_object('code','STANDARD','name','Standard margin floor',
     'min_margin_pct', 0, 'allow_below_cost', false),
   null,
   'Starter Content Packs §7. Below cost is refused and the margin floor is '
   'zero, which is the conservative pair: an organisation that discounts below '
   'cost deliberately raises the floor rather than discovering it was off.', 3140),
  ('base', 'planning_policy', 'DEFAULT',
   jsonb_build_object('code','DEFAULT','name','Default planning policy',
     'reorder_method','reorder_point','safety_stock_basis','statistical',
     'service_level_pct', 95, 'lot_sizing','lot_for_lot',
     'demand_time_fence_days', 7, 'planning_time_fence_days', 28),
   'planning_mrp',
   'Starter Content Packs §7 and §5.4 of the main specification. 95% service '
   'level and a 7/28-day fence pair are the conventional starting point.', 3150)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, requires_capability = excluded.requires_capability,
  provenance = excluded.provenance, seq = excluded.seq;

-- ── §8.1 The chart of accounts, and why it is not here ───────────────────────
--
-- §8.1 specifies nine ranges: 1000s non-current assets, 2000s current assets,
-- 3000s current liabilities including GRNI and tax control, 4000s non-current
-- liabilities and equity, 5000s revenue, 6000s cost of sales including
-- variances, 7000s operating expenses, 8000s other income and expense, 9000s
-- suspense and clearing.
--
-- erp.configure_finance() already installs a chart, and it disagrees with every
-- one of those ranges:
--
--   installed 1000 Bank                    §8.1 1000s are non-current assets
--   installed 1100 Trade receivables       §8.1 puts receivables in 2000s
--   installed 1200 Inventory               §8.1 puts inventory in 2000s
--   installed 2000 Trade payables          §8.1 2000s are current ASSETS
--   installed 2100 GRNI                    §8.1 puts GRNI in 3000s
--   installed 2200 Tax payable             §8.1 puts tax control in 3000s
--   installed 4000 Revenue                 §8.1 4000s are equity and long-term
--   installed 5000 Cost of goods sold      §8.1 5000s are revenue
--   installed 9100 Purchase price variance §8.1 puts variances in 6000s
--   installed 9200 Material usage variance §8.1 9000s are suspense and clearing
--   installed 9300 Labour efficiency variance
--
-- Eleven accounts, eleven collisions, and the posting rules those installers
-- promote point at those codes. Shipping §8.1 would either be refused by
-- erp.pack_conflicts() on the name mismatch — which is the check working — or,
-- worse, silently re-purpose an account a posting rule already reaches.
--
-- So the chart is not in the pack. This is the largest collision in the
-- specification and it is not one to reconcile in passing: renumbering a chart
-- of accounts is a migration for every organisation that has posted anything.
-- Recorded as an open decision, with a report that shows the divergence
-- account by account so the choice is made on evidence.

insert into erp_meta.policy_decision
  (code, title, spec_reference, decision, rationale, status, evidence)
values (
  'chart_of_accounts_ranges',
  'The installed chart of accounts does not follow §8.1''s ranges',
  'Starter Content Packs §8.1',
  'The base pack ships no accounts. erp.configure_finance() remains the only '
  'thing that creates a chart, and §8.1''s range structure is not applied.',
  'Every one of the eleven accounts the finance and inventory and production '
  'installers create sits in a range §8.1 assigns to something else, and the '
  'posting rules those same installers promote reach them by code. Shipping '
  '§8.1 as pack items would be refused by erp.pack_conflicts() on the name '
  'mismatch, or would re-purpose an account a posting rule already points at. '
  'Renumbering is a migration for every organisation that has posted anything, '
  'and it is a decision about the product rather than a line in a content pack.',
  'open',
  'erp.chart_of_accounts_divergence_report() lists the divergence account by '
  'account against §8.1''s ranges.')
on conflict (code) do update set
  decision = excluded.decision, rationale = excluded.rationale,
  evidence = excluded.evidence, status = excluded.status;

create or replace function erp.chart_of_accounts_divergence_report(
  p_tenant_id uuid default null)
returns table (tenant_code text, finding text, reference text)
language sql
stable
set search_path = ''
as $$
  with band(lo, hi, meaning) as (values
    (1000, 1999, 'non-current assets'),
    (2000, 2999, 'current assets'),
    (3000, 3999, 'current liabilities, including GRNI and tax control'),
    (4000, 4999, 'non-current liabilities and equity'),
    (5000, 5999, 'revenue by category'),
    (6000, 6999, 'cost of sales, including purchase price, usage, yield and freight variances'),
    (7000, 7999, 'operating expenses, dimension-analysed'),
    (8000, 8999, 'other income and expense'),
    (9000, 9999, 'suspense and clearing')
  ),
  -- What §8.1's range says an account of this type should be, and what the
  -- account actually is. A mismatch is not automatically wrong — an
  -- organisation may have its own chart — but it is what §8.1 would change.
  expected(account_type, lo) as (values
    ('asset',     2000),
    ('liability', 3000),
    ('equity',    4000),
    ('income',    5000),
    ('expense',   6000)
  )
  select t.code,
         format('%s %s is %s, and §8.1 puts %s in the %s range (%s)',
                a.code, a.name, a.account_type, a.account_type, e.lo, b.meaning),
         a.code
    from erp.account a
    join erp.tenant t on t.id = a.tenant_id
    join expected e on e.account_type = a.account_type::text
    join band b on b.lo = e.lo
   where (p_tenant_id is null or a.tenant_id = p_tenant_id)
     and a.status = 'active'
     and a.code ~ '^[0-9]{4}$'
     and (a.code::integer < e.lo or a.code::integer > e.lo + 999)
   order by t.code, a.code
$$;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function,
   detail_arguments, blurb, runs_in_ci, seq)
values ('chart_of_accounts_ranges', 'Chart of accounts ranges', 'report', 'tenant',
        'chart_of_accounts_divergence_report', '', null, '',
        '§8.1 assigns a meaning to each thousand. This names every account that '
        'sits outside the range its type implies — evidence for a decision, not '
        'a build failure.', false, 27)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  function_name = excluded.function_name, kind = excluded.kind, scope = excluded.scope;

-- ── §8.4 Period close checklist ──────────────────────────────────────────────
--
-- Eleven tasks. erp.configure_period_close() already creates five of them, so
-- the pack ships the six it does not, and nothing is written twice.

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, requires_capability, provenance, seq)
select 'base', 'close_task', c.code,
       jsonb_build_object('code', c.code, 'name', c.name, 'seq', c.seq,
                          'owner_role', c.owner,
                          'depends_on', c.depends,
                          'blocking_check', c.check_fn),
       c.cap, c.why, 4000 + c.seq
  from (values
    ('unposted_sweep', 'Unposted document sweep', 60, 'finance_manager',
     jsonb_build_array('subledgers_reconcile'), null, null,
     'Starter Content Packs §8.4. Blocking: a document that should have posted '
     'and did not is a period that is not complete, whatever the trial balance '
     'says.'),
    ('suspense_clear', 'Suspense clearance', 70, 'finance_manager',
     jsonb_build_array('unposted_sweep'), null, null,
     'Starter Content Packs §8.4, and §13''s last clause: "close a period with '
     'suspense empty". Blocking by construction.'),
    ('intercompany_match', 'Intercompany balance match', 80, 'finance_manager',
     jsonb_build_array('subledgers_reconcile'), null, 'intercompany_trading',
     'Starter Content Packs §8.4. Only meaningful where entities trade with '
     'each other, so it is gated on the capability that makes them.'),
    ('accruals_prepayments', 'Accrual and prepayment posting', 90, 'finance_manager',
     jsonb_build_array('unposted_sweep'), null, null,
     'Starter Content Packs §8.4.'),
    ('provision_review', 'Provision review', 100, 'finance_manager',
     jsonb_build_array('accruals_prepayments'), null, null,
     'Starter Content Packs §8.4. Advisory: a provision is a judgement, and a '
     'checklist that blocks on a judgement blocks for ever.'),
    ('variance_review', 'Variance review', 110, 'finance_manager',
     jsonb_build_array('inventory_valued'), null, null,
     'Starter Content Packs §8.4.'),
    ('consolidation_health', 'Consolidation health', 120, 'finance_manager',
     jsonb_build_array('intercompany_match'), null, 'multi_entity',
     'Starter Content Packs §8.4. Gated on multi-entity, because a single '
     'company consolidates with nothing.'),
    ('evidence_pack', 'Evidence pack assembly', 130, 'finance_manager',
     jsonb_build_array('trial_balance','suspense_clear'), null, null,
     'Starter Content Packs §8.4. Last, and depending on the two that make it '
     'worth assembling.')
  ) c(code, name, seq, owner, depends, check_fn, cap, why)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, requires_capability = excluded.requires_capability,
  provenance = excluded.provenance, seq = excluded.seq;

-- ── §9.1 Scheduled jobs ──────────────────────────────────────────────────────
--
-- Eleven jobs, "shipped disabled, enabled per tenant". Measuring what could
-- actually run them: erp_ref.job_handler held three handlers, one of which —
-- silent-job detection — is on §9.1's own list. Four more of the eleven have a
-- real function behind them already and become handlers here. The remaining
-- six have nothing to run and are recorded rather than shipped, because a job
-- registered against a handler that does nothing is worse than an absent job:
-- it reports success every night.

insert into erp_ref.job_handler
  (code, name_key, description, module_code, sql_function, default_timeout_seconds)
values
  ('inventory.expiry_horizon', 'job_handler.expiry_horizon.name',
   'Batches approaching expiry within the horizon.', 'inventory',
   'expiry_horizon_report', 120),
  ('finance.grni_ageing', 'job_handler.grni_ageing.name',
   'Receipts not yet invoiced, by age bucket.', 'finance',
   'grni_report', 180),
  ('finance.stock_to_ledger', 'job_handler.stock_to_ledger.name',
   'Subledger balances against their control accounts.', 'finance',
   'subledger_reconciliation_report', 300),
  ('integration.backlog', 'job_handler.integration_backlog.name',
   'Commands and events waiting longer than they should.', 'administration',
   'integration_backlog', 60)
on conflict (code) do update set
  name_key = excluded.name_key, description = excluded.description,
  module_code = excluded.module_code, sql_function = excluded.sql_function,
  default_timeout_seconds = excluded.default_timeout_seconds;

insert into erp_ref.resource (key, locale, value, description) values
  ('job_handler.expiry_horizon.name', 'en', 'Expiry horizon sweep',
   'Starter Content Packs §9.1.'),
  ('job_handler.grni_ageing.name', 'en', 'Goods-received-not-invoiced ageing',
   'Starter Content Packs §9.1.'),
  ('job_handler.stock_to_ledger.name', 'en', 'Stock-to-ledger reconciliation',
   'Starter Content Packs §9.1.'),
  ('job_handler.integration_backlog.name', 'en', 'Integration backlog check',
   'Starter Content Packs §9.1.')
on conflict (key, locale) do update set value = excluded.value;

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, requires_capability, provenance, seq)
select 'base', 'job', j.code,
       jsonb_build_object('code', j.code, 'name', j.name,
                          'handler_code', j.handler,
                          'schedule_kind', 'daily', 'at_time', j.at_time,
                          'timezone', 'UTC', 'is_enabled', false),
       j.cap, j.why, 5000 + j.seq
  from (values
    ('expiry_horizon', 'Expiry horizon sweep', 'inventory.expiry_horizon',
     '06:00', 'expiry_control', 10,
     'Starter Content Packs §9.1. Early, so a short-dated batch is known before '
     'the day''s picking starts.'),
    ('grni_ageing', 'Goods-received-not-invoiced ageing', 'finance.grni_ageing',
     '07:00', null, 20,
     'Starter Content Packs §9.1.'),
    ('stock_to_ledger', 'Stock-to-ledger reconciliation', 'finance.stock_to_ledger',
     '05:00', null, 30,
     'Starter Content Packs §9.1. Before the GRNI sweep, because a difference '
     'here explains a difference there.'),
    ('integration_backlog', 'Integration backlog check', 'integration.backlog',
     '08:00', null, 40,
     'Starter Content Packs §9.1.'),
    ('silent_jobs', 'Silent-job detection', 'platform.report_silent_jobs',
     '09:00', null, 50,
     'Starter Content Packs §9.1. The job that notices the others have stopped, '
     'which is why it runs after them.')
  ) j(code, name, handler, at_time, cap, seq, why)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, requires_capability = excluded.requires_capability,
  provenance = excluded.provenance, seq = excluded.seq;

insert into erp_meta.policy_decision
  (code, title, spec_reference, decision, rationale, status, evidence)
values (
  'unimplemented_scheduled_jobs',
  'Six of §9.1''s eleven scheduled jobs have nothing to run',
  'Starter Content Packs §9.1',
  'The base pack ships five jobs. Reservation and staging ageing, count '
  'schedule generation, suspense balance check, approval ageing and '
  'escalation, and document sequence gap check are not shipped.',
  'erp.upsert_job() refuses a handler that does not exist, and '
  'erp.assert_job_handlers_resolvable() refuses a handler naming a function '
  'that does not exist — both correctly. Nothing in this schema computes a '
  'suspense balance, a sequence gap, an approval age or a count schedule, so '
  'a handler for any of them would be a function to write rather than a row '
  'to add. Registering them against a stub would be worse than their absence: '
  'a job that reports success every night over work nobody did is exactly the '
  'failure erp.run_due_jobs() refuses to make for outbound handlers.',
  'open',
  'erp_ref.job_handler holds seven handlers after this migration. §9.1 lists '
  'eleven jobs; five ship. The five with no implementation are named in the '
  'decision.')
on conflict (code) do update set
  decision = excluded.decision, rationale = excluded.rationale,
  evidence = excluded.evidence, status = excluded.status;

-- ── §9.2 Notification templates ──────────────────────────────────────────────
--
-- Thirteen, each with channel routing. The body and subject are resource keys
-- rather than text, so the terminology layer renames them and a tenant that
-- wants its own wording overrides a key rather than editing a template.

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, requires_capability, provenance, seq)
select 'base', 'notification_template', n.code,
       jsonb_build_object('code', n.code, 'channel_kind', n.channel,
                          'subject_key', 'notify.' || n.code || '.subject',
                          'body_key', 'notify.' || n.code || '.body'),
       n.cap, n.why, 6000 + n.seq
  from (values
    ('approval_requested', 'in_app', null, 10,
     'Starter Content Packs §9.2. In-app: an approval request that arrives by '
     'email and is actioned in the product needs the product open anyway.'),
    ('approval_escalated', 'email', null, 20,
     'Starter Content Packs §9.2. Email, because an escalation is for somebody '
     'who was not watching.'),
    ('approval_overdue', 'email', null, 30, 'Starter Content Packs §9.2.'),
    ('receipt_discrepancy', 'in_app', null, 40, 'Starter Content Packs §9.2.'),
    ('match_exception', 'in_app', null, 50, 'Starter Content Packs §9.2.'),
    ('stock_shortage_on_release', 'in_app', null, 60, 'Starter Content Packs §9.2.'),
    ('expiry_threshold_breached', 'email', 'expiry_control', 70,
     'Starter Content Packs §9.2.'),
    ('count_variance_above_tolerance', 'in_app', 'cycle_counting', 80,
     'Starter Content Packs §9.2.'),
    ('quality_event_raised', 'email', 'quality_inspection', 90,
     'Starter Content Packs §9.2.'),
    ('batch_released', 'in_app', 'batch_control', 100,
     'Starter Content Packs §9.2.'),
    ('job_failed', 'email', null, 110,
     'Starter Content Packs §9.2. Email, because a failed job is noticed by '
     'somebody who is not in the product.'),
    ('integration_backlog_above_threshold', 'email', null, 120,
     'Starter Content Packs §9.2.'),
    ('period_close_task_overdue', 'email', null, 130,
     'Starter Content Packs §9.2.')
  ) n(code, channel, cap, seq, why)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, requires_capability = excluded.requires_capability,
  provenance = excluded.provenance, seq = excluded.seq;

-- Every template names two resource keys, and a key that resolves to nothing
-- renders as the key in front of a person.
insert into erp_ref.resource (key, locale, value, description)
select 'notify.' || n.code || '.' || part.k, 'en',
       case part.k when 'subject' then n.subject else n.body end,
       'Starter Content Packs §9.2.'
  from (values
    ('approval_requested', 'Approval requested',
     'A document is waiting for your approval.'),
    ('approval_escalated', 'Approval escalated to you',
     'An approval was not actioned in time and has come to you.'),
    ('approval_overdue', 'Approval overdue',
     'A document has been waiting for approval longer than the band allows.'),
    ('receipt_discrepancy', 'Receipt outside tolerance',
     'A receipt differs from its order by more than the tolerance permits.'),
    ('match_exception', 'Invoice match exception',
     'A supplier invoice did not match its order and receipt within tolerance.'),
    ('stock_shortage_on_release', 'Stock short on release',
     'An order could not be released in full: stock is short.'),
    ('expiry_threshold_breached', 'Batch approaching expiry',
     'A batch has less remaining life than the shelf-life minimum allows.'),
    ('count_variance_above_tolerance', 'Count variance above tolerance',
     'A count found a difference larger than its programme permits.'),
    ('quality_event_raised', 'Quality event raised',
     'A quality event has been raised and needs an investigation.'),
    ('batch_released', 'Batch released',
     'A batch has been released under named authority and is available.'),
    ('job_failed', 'Scheduled job failed',
     'A scheduled job did not complete. Its run record has the reason.'),
    ('integration_backlog_above_threshold', 'Integration backlog',
     'Commands or events have been waiting longer than the threshold allows.'),
    ('period_close_task_overdue', 'Close task overdue',
     'A period close task has passed its due date and the close is blocked.')
  ) n(code, subject, body)
  cross join (values ('subject'), ('body')) part(k)
on conflict (key, locale) do update set
  value = excluded.value, description = excluded.description;

-- ── §9.4 KPI definitions ─────────────────────────────────────────────────────
--
-- Seventeen metrics, "one calculation per metric, centrally defined". The
-- definition ships; the calculation does not, and the difference is deliberate.
-- erp.kpi_version binds a KPI to a governed view and an aggregation, and
-- erp.check_kpi_source_is_traceable() refuses a version whose source cannot be
-- traced. Which governed view exists depends on which modules an organisation
-- installed, so a tenant-neutral pack cannot know it. What the pack can say is
-- what the metric IS — its unit and which direction is good — and that is what
-- stops two people computing "fill rate" two ways.

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, requires_capability, provenance, seq)
select 'base', 'kpi', k.code,
       jsonb_build_object('code', k.code, 'name', k.name, 'unit', k.unit,
                          'higher_is_better', k.higher, 'module_code', k.module,
                          'description', k.description,
                          'currency_scoped', k.ccy),
       k.cap, k.why, 7000 + k.seq
  from (values
    ('stock_accuracy', 'Stock accuracy', 'percent', true, 'inventory', false,
     'Counted quantity against system quantity, by line counted.', null, 10,
     'Starter Content Packs §9.4.'),
    ('inventory_record_accuracy', 'Inventory record accuracy', 'percent', true, 'inventory', false,
     'Locations whose entire content matched, as a share of locations counted. '
     'Stricter than stock accuracy and the one an auditor asks for.', null, 20,
     'Starter Content Packs §9.4.'),
    ('stock_cover_days', 'Stock cover days', 'days', true, 'inventory', false,
     'Stock on hand divided by average daily usage.', null, 30,
     'Starter Content Packs §9.4.'),
    ('slow_moving_value', 'Slow-moving and obsolete value', 'currency', false, 'inventory', true,
     'Value of stock with no movement inside the ageing threshold.', null, 40,
     'Starter Content Packs §9.4. Lower is better, which is why the direction '
     'is on the definition rather than assumed by whoever draws the chart.'),
    ('otif', 'On-time in-full', 'percent', true, 'sales', false,
     'Order lines delivered complete on the promised date, as a share of lines due.', null, 50,
     'Starter Content Packs §9.4.'),
    ('order_to_despatch_hours', 'Order-to-despatch cycle time', 'hours', false, 'sales', false,
     'Median hours from order confirmation to despatch.', null, 60,
     'Starter Content Packs §9.4.'),
    ('fill_rate', 'Fill rate', 'percent', true, 'sales', false,
     'Quantity despatched against quantity ordered, first pass.', null, 70,
     'Starter Content Packs §9.4.'),
    ('supplier_otd', 'Supplier on-time delivery', 'percent', true, 'procurement', false,
     'Receipts on or before the confirmed date, as a share of receipts.', null, 80,
     'Starter Content Packs §9.4.'),
    ('supplier_reject_rate', 'Supplier quality rejection rate', 'percent', false, 'quality', false,
     'Quantity rejected at inspection against quantity received.',
     'quality_inspection', 90,
     'Starter Content Packs §9.4.'),
    ('purchase_price_variance', 'Purchase price variance', 'currency', false, 'finance', true,
     'Invoiced price against standard or last cost, in the period.', null, 100,
     'Starter Content Packs §9.4.'),
    ('grni_ageing', 'Goods-received-not-invoiced ageing', 'currency', false, 'finance', true,
     'Open receipt value by age bucket.', null, 110,
     'Starter Content Packs §9.4.'),
    ('forecast_mape', 'Forecast accuracy (MAPE)', 'percent', false, 'planning', false,
     'Mean absolute percentage error against actual demand.', 'forecasting', 120,
     'Starter Content Packs §9.4. Two measures rather than one, because a '
     'forecast can be accurate and biased at the same time.'),
    ('forecast_bias', 'Forecast bias', 'percent', false, 'planning', false,
     'Signed mean error: positive is over-forecasting.', 'forecasting', 130,
     'Starter Content Packs §9.4.'),
    ('production_yield', 'Production yield', 'percent', true, 'production', false,
     'Good output against material issued.', 'production', 140,
     'Starter Content Packs §9.4.'),
    ('scrap_rate', 'Scrap rate', 'percent', false, 'production', false,
     'Scrapped quantity against quantity produced.', 'production', 150,
     'Starter Content Packs §9.4.'),
    ('recall_readiness_hours', 'Recall readiness time', 'hours', false, 'quality', false,
     'Hours to produce a complete despatch list for one batch.',
     'recall_management', 160,
     'Starter Content Packs §9.4. The metric §13''s recall clause is really '
     'asking about.'),
    ('dso', 'Days sales outstanding', 'days', false, 'finance', false,
     'Receivables divided by average daily sales.', null, 170,
     'Starter Content Packs §9.4.'),
    ('approval_cycle_hours', 'Approval cycle time', 'hours', false, 'administration', false,
     'Median hours from submission to final approval.', null, 180,
     'Starter Content Packs §9.4.')
  ) k(code, name, unit, higher, module, ccy, description, cap, seq, why)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, requires_capability = excluded.requires_capability,
  provenance = excluded.provenance, seq = excluded.seq;

-- ── §9.5 Report catalogue ────────────────────────────────────────────────────

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, requires_capability, provenance, seq)
select 'base', 'report', r.code,
       jsonb_build_object('code', r.code, 'name', r.name,
                          'description', r.description,
                          'module_code', r.module,
                          'kpi_codes', r.kpis,
                          'audience_role_codes', r.audience),
       r.cap, 'Starter Content Packs §9.5.', 8000 + r.seq
  from (values
    ('stock_on_hand', 'Stock on hand and valuation',
     'What is held, where, and what it is worth.', 'inventory',
     'stock_accuracy', 'warehouse_manager,finance_manager,auditor', null, 10),
    ('stock_movement', 'Stock movement',
     'Every movement in a period, with its reason.', 'inventory',
     '', 'warehouse_manager,auditor', null, 20),
    ('expiry_horizon', 'Expiry horizon',
     'Batches by remaining life, against the shelf-life minimums.', 'inventory',
     '', 'warehouse_manager,quality_manager', 'expiry_control', 30),
    ('batch_genealogy', 'Batch genealogy',
     'What a batch was made from and what was made from it.', 'quality',
     '', 'quality_manager,responsible_person', 'batch_control', 40),
    ('open_order_book', 'Open order book',
     'Orders confirmed and not yet despatched, by promised date.', 'sales',
     'fill_rate', 'sales_manager,customer_service', null, 50),
    ('order_fulfilment', 'Order fulfilment performance',
     'On-time and in-full against the promise.', 'sales',
     'otif,order_to_despatch_hours', 'sales_manager,customer_service', null, 60),
    ('purchase_order_status', 'Purchase order status',
     'Orders by state, with what is still outstanding.', 'procurement',
     '', 'procurement_manager,buyer', null, 70),
    ('grni', 'Goods-received-not-invoiced',
     'Received and not yet invoiced, by age.', 'finance',
     'grni_ageing', 'finance_manager,finance_clerk,auditor', null, 80),
    ('match_exceptions', 'Match exceptions',
     'Invoices that did not match within tolerance, and why.', 'procurement',
     '', 'finance_clerk,procurement_manager', null, 90),
    ('supplier_performance', 'Supplier performance',
     'Delivery and quality by supplier.', 'procurement',
     'supplier_otd,supplier_reject_rate', 'procurement_manager,buyer', null, 100),
    ('planning_exceptions', 'Planning exceptions',
     'What the planning run could not resolve.', 'planning',
     '', 'planner', 'planning_mrp', 110),
    ('production_variance', 'Production variance',
     'Material, labour and yield against standard.', 'production',
     'production_yield,scrap_rate', 'production_supervisor,finance_manager',
     'production', 120),
    ('count_accuracy', 'Count accuracy',
     'Variance by programme, location and value band.', 'inventory',
     'stock_accuracy,inventory_record_accuracy', 'warehouse_manager,auditor',
     'cycle_counting', 130),
    ('quality_events', 'Quality events',
     'Events by state, age and root cause.', 'quality',
     '', 'quality_manager,responsible_person', 'quality_inspection', 140),
    ('recall_despatch_list', 'Recall despatch list',
     'Every customer a batch reached. The report §13''s recall clause needs.',
     'quality', 'recall_readiness_hours', 'quality_manager,responsible_person',
     'recall_management', 150),
    ('trial_balance', 'Trial balance',
     'Every account with a movement, by ledger.', 'finance',
     '', 'finance_manager,auditor', null, 160),
    ('dimensional_pl', 'Dimensional profit and loss',
     'Revenue and cost by analysis code.', 'finance',
     '', 'finance_manager,auditor', null, 170),
    ('ageing', 'Receivables and payables ageing',
     'Sales ledger and purchase ledger by age bucket.', 'finance',
     'dso', 'finance_manager,finance_clerk,auditor', null, 180)
  ) r(code, name, description, module, kpis, audience, cap, seq)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, requires_capability = excluded.requires_capability,
  provenance = excluded.provenance, seq = excluded.seq;

-- ── §9.6 Base terminology glossary ───────────────────────────────────────────
--
-- "The keys most commonly overridden, seeded in the base locale so an
-- organisation renames rather than creates." The keys are seeded in
-- erp_ref.resource by the terminology alignment; what belongs in the PACK is a
-- tenant-side override for each, so that renaming is one edit on a row this
-- organisation owns rather than a request to change product content.
--
-- The value is the base term, so applying the pack changes nothing visible.
-- That is the point: it puts the row where a person can edit it.

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, provenance, seq)
select 'base', 'terminology', 'glossary.' || v.code || '|en',
       jsonb_build_object('key', 'glossary.' || v.code, 'locale', 'en',
                          'value', v.product_term),
       format('Starter Content Packs §9.6 and Terminology §6.2. %s',
              coalesce(v.note, v.definition, v.spec_reference)),
       9000 + v.seq
  from erp_ref.vocabulary v
 where v.code in ('goods_in', 'goods_out', 'site', 'business_partner',
                  'product', 'batch', 'requisition', 'works_order',
                  'marshalling_area')
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, provenance = excluded.provenance, seq = excluded.seq;

-- ── §9.3 Document and label output templates ─────────────────────────────────
--
-- Sixteen templates: purchase order, order acknowledgement, goods receipt note,
-- picking ticket, packing note, delivery note, commercial invoice, credit note,
-- pro-forma, transfer note, works order pack, certificate of analysis, pallet
-- label, carton label, bin label, returns label.
--
-- There is nowhere to put them. erp.notification_template carries messages,
-- erp.code_template carries product code shapes, and neither renders a
-- document. No table in this schema holds a document or label layout, and no
-- change-set kind can carry one — so sixteen items would be a pack that fails
-- on application.

insert into erp_meta.policy_decision
  (code, title, spec_reference, decision, rationale, status, evidence)
values (
  'no_output_template_surface',
  '§9.3''s sixteen output templates have nowhere to go',
  'Starter Content Packs §9.3',
  'The base pack ships no document or label templates. §9.3 is not implemented.',
  'The schema has three template tables — close_task_template, code_template '
  'and notification_template — and none of them renders a delivery note or a '
  'pallet label. §9.3 also says the layouts are "tenant-brandable through the '
  'resource and branding layer", which exists, so the missing half is the '
  'layout surface itself: a table, a change-set kind, and a renderer. That is '
  'a subsystem, not pack content.',
  'open',
  'erp.notification_template is the only template surface with a promoter '
  'branch, and it carries a channel and two resource keys — a message, not a '
  'document.')
on conflict (code) do update set
  decision = excluded.decision, rationale = excluded.rationale,
  evidence = excluded.evidence, status = excluded.status;

select erp.assert_packs_installable();
select erp.assert_job_handlers_resolvable();
select erp.assert_resource_coverage('en');
select erp.assert_diagnostics_registered();
select erp.assert_public_api_safe();

insert into erp_meta.policy_decision
  (code, title, spec_reference, decision, rationale, status, evidence)
values (
  'receipt_tolerance_breach_actions',
  '§7''s three breach behaviours are not the three the schema offers',
  'Starter Content Packs §7',
  'The pack maps block to reject, warn to accept and route-to-approval to '
  'quarantine. erp.receipt_tolerance.over_action is unchanged.',
  'A quarantined over-receipt is not the same as one routed to an approval '
  'band: quarantine is a place stock sits, approval is a decision somebody '
  'makes, and the second implies an approval chain the column cannot name. '
  'Widening the check constraint to add an approve action would need the '
  'receiving path to build an approval request, which is a behaviour change '
  'rather than a content one.',
  'open',
  'erp.receipt_tolerance.over_action allows accept, reject and quarantine. §7 '
  'names block, warn and route to approval. Neither set contains the other.')
on conflict (code) do update set
  decision = excluded.decision, rationale = excluded.rationale,
  evidence = excluded.evidence, status = excluded.status;
