-- =============================================================================
-- Starter Content Packs §10 — the six profile packs
--
-- "Applied over the base, each switchable, each adding only what its
-- capabilities need."
--
-- That last clause is the whole shape. A profile pack names one capability, and
-- erp.assert_packs_installable() refuses one that does not — because a profile
-- pack with no capability adds unconditionally, which makes it a second base
-- pack wearing a label. Its items are then gated individually as well, so
-- Manufacturing applied without serialisation brings works order types and not
-- serial-numbered rework.
--
-- These are smaller than the base pack on purpose. §10 says each adds only what
-- its capabilities need, and most of what a distribution or a manufacturing
-- organisation needs is already in the base pack — the profile is the
-- difference, not the whole.
-- =============================================================================

insert into erp_ref.content_pack
  (code, name, description, kind, version, requires_capability, provenance, seq) values
  ('distribution', 'Distribution',
   'Buy and sell without transformation: drop-ship and cross-dock behaviour, '
   'and the consolidation rules that decide what ships together.',
   'profile', '1.0.0', 'consignment_stock',
   'Starter Content Packs §10, distribution. Drop-ship and cross-dock are the '
   'two flows that separate a distributor from a manufacturer, and both '
   'separate ownership from custody, which is what consignment models.', 20),

  ('manufacturing', 'Manufacturing',
   'Works order types, production reason codes, routing and work-centre '
   'starters, backflush policy defaults and yield tolerance bands.',
   'profile', '1.0.0', 'production',
   'Starter Content Packs §10, manufacturing. Works order types follow the '
   'five the section names: production, assembly, kitting, rework, repack.', 30),

  ('regulated', 'Regulated goods',
   'Quarantine on receipt by accounting code, release authority, a '
   'controlled-substance axis, recall reason codes and regulatory clocks, '
   'deviation states and electronic signature requirements.',
   'profile', '1.0.0', 'quarantine_release',
   'Starter Content Packs §10, regulated goods. Built on quarantine and '
   'release rather than on quality inspection, because §10''s list is about '
   'what happens after an inspection decides.', 40),

  ('multi_entity', 'Multi-entity',
   'Intercompany accounting codes and matched postings, transfer pricing '
   'placeholders, elimination analysis codes, group currency and rate types.',
   'profile', '1.0.0', 'intercompany_trading',
   'Starter Content Packs §10, multi-entity. Gated on intercompany trading '
   'rather than on multi-entity itself: two companies that never trade need '
   'none of this, and intercompany trading already requires multi-entity.', 50),

  ('channel_sales', 'Channel sales',
   'Order intake states for automated upstream systems, hold types with '
   'release authority, cancellation cut-offs, prepaid settlement and clearing, '
   'and the events sent back to the originating system.',
   'profile', '1.0.0', 'automated_order_intake',
   'Starter Content Packs §10, channel sales.', 60),

  ('outsourced_logistics', 'Outsourced logistics',
   'Third-party custody location behaviour, provider reconciliation cadence, '
   'custody-versus-ownership defaults and discrepancy handling.',
   'profile', '1.0.0', 'third_party_custody',
   'Starter Content Packs §10, outsourced logistics.', 70)
on conflict (code) do update set
  name = excluded.name, description = excluded.description,
  version = excluded.version, requires_capability = excluded.requires_capability,
  provenance = excluded.provenance, seq = excluded.seq;

-- ── Distribution ─────────────────────────────────────────────────────────────

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, requires_capability, provenance, seq)
values
  ('distribution', 'config', 'sales.backorder_policy||-|-',
   jsonb_build_object('config_type', 'sales.backorder_policy',
     'value', jsonb_build_object('default', 'partial_ship',
       'by_channel', jsonb_build_object('dropship', 'refuse'))),
   null,
   'Starter Content Packs §10, distribution. A distributor ships what it has '
   'and follows with the rest; a drop-ship line cannot be partially shipped at '
   'all, because the supplier ships it whole or not at all.', 10),
  ('distribution', 'posting_class', 'item|CROSSDOCK',
   jsonb_build_object('kind','item','code','CROSSDOCK','name','Cross-docked goods',
     'description','Received and despatched without being put away, so it never '
     'reaches a storage location and never carries a storage cost.'),
   null,
   'Starter Content Packs §10, distribution. Cross-dock is a posting question '
   'as much as a movement one: goods that never rest do not absorb handling.', 20),
  ('distribution', 'posting_class', 'item|DROPSHIP',
   jsonb_build_object('kind','item','code','DROPSHIP','name','Drop-shipped goods',
     'description','Sold and invoiced here, shipped by the supplier direct to '
     'the customer, and never held.'),
   null,
   'Starter Content Packs §10, distribution.', 21),
  ('distribution', 'reason_code', 'ORDER_HOLD|CONSOLIDATION',
   jsonb_build_object('category','ORDER_HOLD','code','CONSOLIDATION',
     'name','Awaiting consolidation','requires_note',false,'seq',20),
   null,
   'Starter Content Packs §10, distribution: "consolidation rules". A line '
   'held to ship with the rest of an order is not the same hold as a credit '
   'stop, and a report that cannot tell them apart cannot be acted on.', 30),
  ('distribution', 'config', 'stock.reservation_ageing||-|-',
   jsonb_build_object('config_type', 'stock.reservation_ageing',
     'value', jsonb_build_object('detailed_allocation_hours', 8,
                                 'marshalling_area_hours', 24)),
   null,
   'Starter Content Packs §10, distribution. Shorter than the base pack: a '
   'distributor turns stock in hours, and a day-long reservation on a fast '
   'line starves the next order.', 40)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, requires_capability = excluded.requires_capability,
  provenance = excluded.provenance, seq = excluded.seq;

-- ── Manufacturing ────────────────────────────────────────────────────────────

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, requires_capability, provenance, seq)
values
  ('manufacturing', 'classification_axis', 'WORKS_ORDER_TYPE',
   jsonb_build_object('code','WORKS_ORDER_TYPE','name','Works order type',
     'is_mandatory', true, 'seq', 110),
   null,
   'Starter Content Packs §10, manufacturing: "works order types (production, '
   'assembly, kitting, rework, repack)". Mandatory, because the five behave '
   'differently enough that an unclassified works order cannot be costed.', 10),
  ('manufacturing', 'classification_value', 'WORKS_ORDER_TYPE|PRODUCTION',
   jsonb_build_object('axis','WORKS_ORDER_TYPE','code','PRODUCTION',
     'name','Production','abbreviation','PROD'),
   null, 'Starter Content Packs §10, manufacturing.', 11),
  ('manufacturing', 'classification_value', 'WORKS_ORDER_TYPE|ASSEMBLY',
   jsonb_build_object('axis','WORKS_ORDER_TYPE','code','ASSEMBLY',
     'name','Assembly','abbreviation','ASM'),
   null, 'Starter Content Packs §10, manufacturing.', 12),
  ('manufacturing', 'classification_value', 'WORKS_ORDER_TYPE|KITTING',
   jsonb_build_object('axis','WORKS_ORDER_TYPE','code','KITTING',
     'name','Kitting','abbreviation','KIT'),
   null, 'Starter Content Packs §10, manufacturing.', 13),
  ('manufacturing', 'classification_value', 'WORKS_ORDER_TYPE|REWORK',
   jsonb_build_object('axis','WORKS_ORDER_TYPE','code','REWORK',
     'name','Rework','abbreviation','RWK'),
   null, 'Starter Content Packs §10, manufacturing.', 14),
  ('manufacturing', 'classification_value', 'WORKS_ORDER_TYPE|REPACK',
   jsonb_build_object('axis','WORKS_ORDER_TYPE','code','REPACK',
     'name','Repack','abbreviation','RPK'),
   null, 'Starter Content Packs §10, manufacturing.', 15),
  ('manufacturing', 'config', 'production.issue_method||-|-',
   jsonb_build_object('config_type','production.issue_method','value', to_jsonb('backflush'::text)),
   null,
   'Starter Content Packs §10, manufacturing: "backflush policy defaults". '
   'Backflush is the default because it is what most works orders want; an '
   'operation that needs a scan per issue says so at the site level, which is '
   'why this config type''s scope is site.', 20),
  ('manufacturing', 'reason_code', 'SCRAP|YIELD_LOSS',
   jsonb_build_object('category','SCRAP','code','YIELD_LOSS','name','Yield loss',
     'requires_note', true, 'seq', 20),
   null,
   'Starter Content Packs §10, manufacturing: "production reason codes". Yield '
   'loss is not damage and not obsolescence — it is the process behaving as it '
   'does, and a scrap report that cannot separate it cannot show a trend.', 30),
  ('manufacturing', 'reason_code', 'SCRAP|SET_UP',
   jsonb_build_object('category','SCRAP','code','SET_UP','name','Set-up loss',
     'requires_note', false, 'seq', 21),
   null,
   'Starter Content Packs §10, manufacturing. Expected on every run, so it '
   'needs no note; counting it as damage would make every line look damaged.', 31),
  ('manufacturing', 'reason_code', 'SCRAP|REWORK_FAILED',
   jsonb_build_object('category','SCRAP','code','REWORK_FAILED',
     'name','Rework unsuccessful','requires_note', true, 'seq', 22),
   null, 'Starter Content Packs §10, manufacturing.', 32),
  ('manufacturing', 'reason_code', 'BATCH_AMENDMENT|YIELD_RECONCILIATION',
   jsonb_build_object('category','BATCH_AMENDMENT','code','YIELD_RECONCILIATION',
     'name','Yield reconciliation','requires_note', true,
     'requires_approval', true, 'seq', 20),
   'batch_control',
   'Starter Content Packs §10, manufacturing, and §5.2''s batch amendment '
   'category. Gated on batch control, because a yield reconciliation against '
   'no batch is a number with nothing to attach to.', 33),
  ('manufacturing', 'config', 'quality.quarantine_defaults||-|-',
   jsonb_build_object('config_type','quality.quarantine_defaults',
     'value', jsonb_build_object(
       'posting_classes', jsonb_build_array('RAW','SFG','FG'),
       'ageing_days_warn', 3, 'ageing_days_escalate', 7)),
   'quality_inspection',
   'Starter Content Packs §10, manufacturing: "yield tolerance bands" needs '
   'semi-finished goods inspected too, which the base pack''s two-class default '
   'does not cover.', 40),
  ('manufacturing', 'kpi', 'first_pass_yield',
   jsonb_build_object('code','first_pass_yield','name','First pass yield',
     'unit','percent','higher_is_better', true, 'module_code','production',
     'description','Good output at the first attempt, before any rework.'),
   null,
   'Starter Content Packs §10, manufacturing. Distinct from §9.4''s production '
   'yield, which counts reworked output as good — the two diverge exactly where '
   'a process is unstable, which is the case worth seeing.', 50)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, requires_capability = excluded.requires_capability,
  provenance = excluded.provenance, seq = excluded.seq;

-- ── Regulated goods ──────────────────────────────────────────────────────────

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, requires_capability, provenance, seq)
values
  ('regulated', 'classification_axis', 'CONTROLLED_SUBSTANCE',
   jsonb_build_object('code','CONTROLLED_SUBSTANCE','name','Controlled substance schedule',
     'is_mandatory', false, 'seq', 120),
   null,
   'Starter Content Packs §10, regulated goods: "controlled-substance '
   'classification axis". The schedules themselves are jurisdictional and '
   'belong to a legislation pack; the axis is not.', 10),
  ('regulated', 'config', 'quality.quarantine_defaults||-|-',
   jsonb_build_object('config_type','quality.quarantine_defaults',
     'value', jsonb_build_object(
       'posting_classes', jsonb_build_array('RAW','SFG','FG','PACK','SAMPLE'),
       'ageing_days_warn', 2, 'ageing_days_escalate', 5)),
   null,
   'Starter Content Packs §10, regulated goods: "quarantine-on-receipt '
   'defaults by class". Packaging is included, because primary packaging in '
   'contact with product is itself controlled, and samples because a sample '
   'that skipped quarantine proves nothing.', 20),
  ('regulated', 'config', 'stock.shelf_life_minimum||-|-',
   jsonb_build_object('config_type','stock.shelf_life_minimum',
     'value', jsonb_build_object('on_receipt_pct', 85, 'on_transfer_pct', 70,
                                 'on_despatch_pct', 50)),
   'expiry_control',
   'Starter Content Packs §10, regulated goods. Tighter than the base pack''s '
   '75/50/33, because a regulated customer''s own acceptance criteria are '
   'usually stricter than a distributor''s.', 30),
  ('regulated', 'reason_code', 'BATCH_AMENDMENT|DEVIATION_RAISED',
   jsonb_build_object('category','BATCH_AMENDMENT','code','DEVIATION_RAISED',
     'name','Deviation raised','requires_note', true, 'requires_approval', true,
     'seq', 30),
   'batch_control',
   'Starter Content Packs §10, regulated goods: "deviation and corrective-'
   'action states". The state machine is §5.6''s quality event, which the base '
   'pack ships; this is the reason that opens one against a batch.', 40),
  ('regulated', 'reason_code', 'BATCH_AMENDMENT|CAPA_CLOSED',
   jsonb_build_object('category','BATCH_AMENDMENT','code','CAPA_CLOSED',
     'name','Corrective action closed','requires_note', true,
     'requires_approval', true, 'seq', 31),
   'batch_control',
   'Starter Content Packs §10, regulated goods.', 41),
  ('regulated', 'reason_code', 'SCRAP|REGULATORY_DESTRUCTION',
   jsonb_build_object('category','SCRAP','code','REGULATORY_DESTRUCTION',
     'name','Destruction under regulatory instruction','requires_note', true,
     'requires_approval', true, 'seq', 30),
   null, 'Starter Content Packs §10, regulated goods.', 42),
  ('regulated', 'sod_rule', 'INSPECT_AND_RELEASE',
   jsonb_build_object('code','INSPECT_AND_RELEASE',
     'name','Inspect a batch and release it',
     'permissions_a','quality.inspect','permissions_b','quality.release_batch',
     'severity','prohibited',
     'description','The person who performed the test cannot also be the named '
     'authority that accepts it.',
     'mitigation','None. This is what "released under named authority" means.'),
   'quarantine_release',
   'Starter Content Packs §10, regulated goods: "release authority roles". '
   'Stricter than §3.3''s amend-and-release, which the base pack ships: here '
   'even performing the inspection disqualifies you from releasing on it.', 50),
  ('regulated', 'notification_template', 'deviation_raised',
   jsonb_build_object('code','deviation_raised','channel_kind','email',
     'subject_key','notify.deviation_raised.subject',
     'body_key','notify.deviation_raised.body'),
   null,
   'Starter Content Packs §10, regulated goods. Email rather than in-app, '
   'because a deviation has a regulatory clock and waiting for somebody to '
   'open the product is not a plan.', 60),
  ('regulated', 'job', 'quarantine_ageing',
   jsonb_build_object('code','quarantine_ageing','name','Quarantine ageing',
     'handler_code','inventory.expiry_horizon','schedule_kind','daily',
     'at_time','06:30','timezone','UTC','is_enabled', false),
   'expiry_control',
   'Starter Content Packs §10, regulated goods, reading the expiry horizon so '
   'that stock ageing in quarantine is seen before its shelf life is the '
   'problem rather than the quarantine.', 70)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, requires_capability = excluded.requires_capability,
  provenance = excluded.provenance, seq = excluded.seq;

insert into erp_ref.resource (key, locale, value, description) values
  ('notify.deviation_raised.subject', 'en', 'Deviation raised',
   'Starter Content Packs §10, regulated goods.'),
  ('notify.deviation_raised.body', 'en',
   'A deviation has been raised against a batch and needs an investigation '
   'and a corrective action.',
   'Starter Content Packs §10, regulated goods.')
on conflict (key, locale) do update set value = excluded.value;

-- ── Multi-entity ─────────────────────────────────────────────────────────────

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, requires_capability, provenance, seq)
values
  ('multi_entity', 'classification_axis', 'ELIMINATION',
   jsonb_build_object('code','ELIMINATION','name','Elimination group',
     'is_mandatory', false, 'seq', 130),
   null,
   'Starter Content Packs §10, multi-entity: "elimination dimension values". '
   'The axis ships empty — which groups eliminate against which is the '
   'group''s own structure, and a pack that guessed it would be guessing a '
   'consolidation.', 10),
  ('multi_entity', 'posting_class', 'party|IC_SERVICE',
   jsonb_build_object('kind','party','code','IC_SERVICE',
     'name','Intercompany services',
     'description','Recharges and shared costs between entities, which post '
     'differently from intercompany goods and eliminate on a different line.'),
   null,
   'Starter Content Packs §10, multi-entity. §4.4''s SUP_IC and CUST_IC cover '
   'goods; services are the half that trips consolidation up.', 20),
  ('multi_entity', 'close_task', 'transfer_pricing_review',
   jsonb_build_object('code','transfer_pricing_review',
     'name','Transfer pricing review', 'seq', 85,
     'owner_role','finance_manager',
     'depends_on', jsonb_build_array('intercompany_match')),
   null,
   'Starter Content Packs §10, multi-entity: "transfer pricing method '
   'placeholders". A placeholder that is not on the close checklist is a '
   'placeholder nobody fills in.', 30),
  ('multi_entity', 'reason_code', 'PERIOD_REOPEN|GROUP_ADJUSTMENT',
   jsonb_build_object('category','PERIOD_REOPEN','code','GROUP_ADJUSTMENT',
     'name','Group adjustment','requires_note', true, 'requires_approval', true,
     'seq', 20),
   null,
   'Starter Content Packs §10, multi-entity. §6''s consolidation adjustment '
   'is the entity''s own; this is one imposed from above it.', 40)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, requires_capability = excluded.requires_capability,
  provenance = excluded.provenance, seq = excluded.seq;

-- ── Channel sales ────────────────────────────────────────────────────────────

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, requires_capability, provenance, seq)
values
  ('channel_sales', 'reason_code', 'ORDER_HOLD|UPSTREAM_VALIDATION',
   jsonb_build_object('category','ORDER_HOLD','code','UPSTREAM_VALIDATION',
     'name','Awaiting upstream validation','requires_note', false, 'seq', 30),
   null,
   'Starter Content Packs §10, channel sales: "order intake states for '
   'automated upstream systems". An order that arrived from a machine and has '
   'not been confirmed by it is held for a reason no person caused.', 10),
  ('channel_sales', 'reason_code', 'ORDER_HOLD|PAYMENT_AUTHORISATION',
   jsonb_build_object('category','ORDER_HOLD','code','PAYMENT_AUTHORISATION',
     'name','Awaiting payment authorisation','requires_note', false, 'seq', 31),
   'prepaid_settlement',
   'Starter Content Packs §10, channel sales: "prepaid settlement and clearing '
   'rules". Distinct from §6''s payment pending, which is a credit-terms hold '
   'on an invoice rather than a settlement that has not cleared.', 11),
  ('channel_sales', 'reason_code', 'ORDER_CANCEL|PAST_CHANNEL_CUT_OFF',
   jsonb_build_object('category','ORDER_CANCEL','code','PAST_CHANNEL_CUT_OFF',
     'name','Past the channel cut-off','requires_note', false, 'seq', 20),
   null,
   'Starter Content Packs §10, channel sales: "cancellation cut-off '
   'definitions". §6''s past cut-off is the warehouse''s; this is the '
   'channel''s, and they are different times of day.', 20),
  ('channel_sales', 'posting_class', 'party|CUST_MARKETPLACE',
   jsonb_build_object('kind','party','code','CUST_MARKETPLACE',
     'name','Marketplace customer',
     'description','The marketplace is the party invoiced; the consumer is the '
     'party delivered to, and they settle on different terms.'),
   null,
   'Starter Content Packs §10, channel sales.', 30),
  ('channel_sales', 'config', 'sales.credit_control||-|-',
   jsonb_build_object('config_type','sales.credit_control',
     'value', jsonb_build_object('check_at_capture', false,
       'block_at_limit', false, 'tolerance_pct', 0, 'overdue_days_block', 0)),
   'prepaid_settlement',
   'Starter Content Packs §10, channel sales. Credit checking is off where '
   'settlement is prepaid: money arrives before goods leave, so there is no '
   'credit to control and a limit check would refuse orders already paid for.', 40),
  ('channel_sales', 'notification_template', 'order_intake_rejected',
   jsonb_build_object('code','order_intake_rejected','channel_kind','webhook',
     'subject_key','notify.order_intake_rejected.subject',
     'body_key','notify.order_intake_rejected.body'),
   null,
   'Starter Content Packs §10, channel sales: "notification events back to the '
   'originating system". Webhook, because the recipient is a machine — the '
   'only template in any pack that is not addressed to a person.', 50)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, requires_capability = excluded.requires_capability,
  provenance = excluded.provenance, seq = excluded.seq;

insert into erp_ref.resource (key, locale, value, description) values
  ('notify.order_intake_rejected.subject', 'en', 'Order rejected at intake',
   'Starter Content Packs §10, channel sales.'),
  ('notify.order_intake_rejected.body', 'en',
   'An order received from an upstream system could not be accepted. The '
   'reason is on the order.',
   'Starter Content Packs §10, channel sales.')
on conflict (key, locale) do update set value = excluded.value;

-- ── Outsourced logistics ─────────────────────────────────────────────────────

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, requires_capability, provenance, seq)
values
  ('outsourced_logistics', 'posting_class', 'party|PROVIDER_3PL',
   jsonb_build_object('kind','party','code','PROVIDER_3PL',
     'name','Logistics provider',
     'description','Holds stock it does not own. Invoices for handling and '
     'storage, never for the goods.'),
   null,
   'Starter Content Packs §10, outsourced logistics: "custody-versus-ownership '
   'defaults". §4.4''s CARRIER moves goods; a provider keeps them, and the '
   'two post differently.', 10),
  ('outsourced_logistics', 'reason_code', 'STOCK_ADJUSTMENT|PROVIDER_DISCREPANCY',
   jsonb_build_object('category','STOCK_ADJUSTMENT','code','PROVIDER_DISCREPANCY',
     'name','Provider reconciliation discrepancy','requires_note', true,
     'requires_approval', true, 'seq', 20),
   null,
   'Starter Content Packs §10, outsourced logistics: "discrepancy handling". '
   'Approval required, because a difference against a provider''s own count is '
   'a commercial conversation before it is an adjustment.', 20),
  ('outsourced_logistics', 'job', 'provider_reconciliation',
   jsonb_build_object('code','provider_reconciliation',
     'name','Third-party custody reconciliation',
     'handler_code','finance.stock_to_ledger','schedule_kind','weekly',
     'at_time','04:00','days_of_week','1','timezone','UTC','is_enabled', false),
   null,
   'Starter Content Packs §10, outsourced logistics: "provider reconciliation '
   'cadence". Weekly on a Monday, which is when a provider''s own week-end '
   'count is available.', 30),
  ('outsourced_logistics', 'config', 'stock.reservation_ageing||-|-',
   jsonb_build_object('config_type','stock.reservation_ageing',
     'value', jsonb_build_object('detailed_allocation_hours', 72,
                                 'marshalling_area_hours', 168)),
   null,
   'Starter Content Packs §10, outsourced logistics. Longer than the base '
   'pack, not shorter: an instruction sent to a provider is not acted on in '
   'the same hour, and a reservation that ages out while the provider is still '
   'picking creates a shortage that is not real.', 40)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, requires_capability = excluded.requires_capability,
  provenance = excluded.provenance, seq = excluded.seq;

select erp.assert_packs_installable();
select erp.assert_resource_coverage('en');
select erp.assert_capabilities_sound();
select erp.assert_diagnostics_registered();
