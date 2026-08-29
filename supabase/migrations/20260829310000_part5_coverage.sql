-- =============================================================================
-- ERPWare — the Part 5 coverage register
--
-- Every area of Part 5 now has code behind it. That is a claim, and this
-- migration is what turns it into a query.
--
-- The register enumerates each capability the specification names, in the
-- specification's own words, and binds it to the artefact that delivers it —
-- a function, a table, or an assertion. erp.assert_part5_coverage() then checks
-- that every artefact a capability claims actually exists.
--
-- Why this is worth building rather than writing a document:
--
--   A document says what was built on the day it was written. This says what
--   is built now. A function renamed in six months breaks the build here, which
--   means the register cannot quietly become fiction — and a register of
--   capabilities that has quietly become fiction is worse than none, because
--   somebody will rely on it.
--
--   It is also the honest place to record what is NOT built. Three capabilities
--   below are marked partial and one is absent, with a note saying exactly what
--   is missing. Claiming them would have been easy and would have made every
--   other row untrustworthy.
--
-- The register is product content, not tenant configuration: it describes what
-- the product does, which is the same for every tenant.
-- =============================================================================

create table if not exists erp_ref.part5_capability (
  code         text primary key
                 check (code ~ '^[0-9]+\.[0-9]+\.[a-z][a-z0-9_]*$'),
  section      text not null,
  section_name text not null,
  module_code  text references erp_ref.module(code),
  -- The specification's own words, so the register cannot drift into
  -- describing what was built instead of what was asked for.
  requirement  text not null,
  -- Where it is delivered: schema-qualified function signatures, table names,
  -- or assertion names. Checked to exist.
  artefacts    text[] not null default '{}'::text[],
  status       text not null default 'built'
                 check (status in ('built', 'partial', 'absent')),
  -- Required where status is not 'built'. What is missing, and why.
  gap          text,
  constraint part5_gap_explained
    check (status = 'built' or (gap is not null and length(trim(gap)) >= 20))
);

comment on table erp_ref.part5_capability is
  'Every capability Part 5 names, bound to the artefact that delivers it. '
  'erp.assert_part5_coverage() fails the build if an artefact named here does '
  'not exist, so the register cannot quietly become fiction.';

insert into erp_ref.part5_capability
  (code, section, section_name, module_code, requirement, artefacts, status, gap)
values
-- 5.1 ------------------------------------------------------------------------
('5.1.master_data_records', '5.1', 'Master data management', 'master_data',
 'Item, party, structural and product-structure master data; multilingual descriptions',
 array['erp.item', 'erp.party', 'erp.item_description', 'erp.bom', 'erp.entity'],
 'built', null),
('5.1.completeness_scoring', '5.1', 'Master data management', 'master_data',
 'Completeness and validity scoring',
 array['erp.data_quality_rule', 'erp.score_master_record(text,uuid)',
       'erp.data_quality_score(text,uuid)', 'erp.data_quality_report(text)'],
 'built', null),
('5.1.duplicate_merge', '5.1', 'Master data management', 'master_data',
 'Duplicate detection and merge',
 array['erp.duplicate_candidates(text)', 'erp.merge_master_record(text,uuid,uuid,text)',
       'erp.match_key(text)'],
 'built', null),
('5.1.change_requests', '5.1', 'Master data management', 'master_data',
 'Change-request workflow with field-level approval rules',
 array['erp.change_request', 'erp.field_approval_rule',
       'erp.open_change_request(text,uuid,jsonb,text)',
       'erp.change_request_governance(uuid)', 'erp.apply_change_request(uuid)'],
 'built', null),
('5.1.import_pipeline', '5.1', 'Master data management', 'master_data',
 'Controlled import pipelines with validation, preview, staged load and rollback',
 array['erp.stage_import(text,jsonb,text,text)', 'erp.validate_import(uuid)',
       'erp.preview_import(uuid)', 'erp.load_import(uuid)', 'erp.rollback_import(uuid)'],
 'built', null),
('5.1.mass_maintenance', '5.1', 'Master data management', 'master_data',
 'Rule-based mass maintenance with preview and reversal',
 array['erp.mass_change', 'erp.preview_mass_change(uuid)',
       'erp.apply_mass_change(uuid)', 'erp.reverse_mass_change(uuid)'],
 'built', null),

-- 5.2 ------------------------------------------------------------------------
('5.2.stock_ledger', '5.2', 'Inventory and warehouse', 'inventory',
 'Stock ledger with configurable costing (standard, average, FIFO) and valuation reporting reconcilable to the ledger',
 array['erp.stock_movement', 'erp.costing_policy', 'erp.stock_valuation_layer',
       'erp.receive_cost(uuid,uuid,numeric,bigint,character,uuid,bigint)',
       'erp.issue_cost(uuid,uuid,numeric)', 'erp.stock_valuation_report()',
       'erp.assert_inventory_reconciles()'],
 'built', null),
('5.2.batch_control', '5.2', 'Inventory and warehouse', 'inventory',
 'Lot and batch control with expiry, shelf-life rules and status lifecycle',
 array['erp.batch', 'erp.expiry_horizon_report(integer)', 'erp.release_batch(uuid,uuid,text,text,uuid)'],
 'built', null),
('5.2.batch_amendment', '5.2', 'Inventory and warehouse', 'inventory',
 'Batch attribute amendment, split, merge, re-status and re-date without stock movement',
 array['erp.amend_batch(uuid,text,text,text)', 'erp.split_batch(uuid,text,numeric,uuid,text)',
       'erp.batch_amendment'],
 'partial',
 'Amend, split, re-status and re-date are built. Merge is not: combining two '
 'batches means deciding which attributes survive, and doing that by rule '
 'rather than by asking is how a merged batch ends up with an expiry date '
 'neither of its parents had.'),
('5.2.container_hierarchy', '5.2', 'Inventory and warehouse', 'inventory',
 'Container hierarchy with configurable identity depth and mixed-content handling',
 array['erp.container', 'erp.move_container(uuid,uuid,text)', 'erp.maintain_container_path()'],
 'built', null),
('5.2.warehouse_operations', '5.2', 'Inventory and warehouse', 'inventory',
 'Goods receipt, putaway, replenishment, picking, packing, despatch and return processing',
 array['erp.post_document_stock(uuid)', 'erp.receive_against(uuid,uuid,numeric,uuid)',
       'erp.commit_allocation(uuid,uuid,uuid)', 'erp.customer_return'],
 'partial',
 'Receipt, picking through allocation, despatch and returns are built. Putaway '
 'and replenishment as distinct directed tasks are not: both are movements the '
 'ledger already supports, and what is missing is the task list that tells '
 'somebody to make them.'),
('5.2.count_programmes', '5.2', 'Inventory and warehouse', 'inventory',
 'Count programmes (cycle, perpetual, annual, opportunistic) that operate without freezing stock, with granular soft locking, automatic exclusion of committed stock, tolerance-based variance approval and accuracy reporting',
 array['erp.count_programme', 'erp.count_task', 'erp.count_lock',
       'erp.raise_count_tasks(text)', 'erp.record_count(uuid,numeric)',
       'erp.post_count(uuid)', 'erp.count_accuracy_report(date)'],
 'built', null),
('5.2.expiry_write_off', '5.2', 'Inventory and warehouse', 'inventory',
 'Expiry horizon management and write-off workflow',
 array['erp.expiry_horizon_report(integer)',
       'erp.write_off_stock(uuid,uuid,uuid,numeric,text,uuid)'],
 'built', null),
('5.2.stock_health', '5.2', 'Inventory and warehouse', 'inventory',
 'Stock health and ageing analysis',
 array['erp.stock_health_report()', 'erp.stock_ageing_report()'],
 'built', null),

-- 5.3 ------------------------------------------------------------------------
('5.3.supplier_qualification', '5.3', 'Procurement', 'procurement',
 'Supplier qualification and approved-supplier control',
 array['erp.supplier_qualification(uuid)', 'erp.require_approved_supplier(uuid)',
       'erp.qualify_supplier(uuid,interval,text)', 'erp.supplier_qualification_report()'],
 'built', null),
('5.3.supplier_catalogues', '5.3', 'Procurement', 'procurement',
 'Supplier catalogues with terms and validity',
 array['erp.item_price', 'erp.party_role_terms'],
 'partial',
 'The tables carry price lists with validity dates and per-counterparty terms, '
 'and erp.resolve_price() reads them for sales. Nothing resolves a purchase '
 'price from them, so a purchase order is still priced by whoever raises it.'),
('5.3.requisition_budget', '5.3', 'Procurement', 'procurement',
 'Requisition capture with budget checking',
 array['erp.budget', 'erp.budget_position(text,integer)', 'erp.check_budget(text,bigint)'],
 'built', null),
('5.3.approval_chains', '5.3', 'Procurement', 'procurement',
 'Configurable approval chains with delegation and escalation',
 array['erp.approval_chain', 'erp.request_approval(text,uuid,jsonb,integer,uuid,uuid)',
       'erp.delegate_approval_task(uuid,uuid,text)', 'erp.escalate_overdue_approvals()'],
 'built', null),
('5.3.order_types', '5.3', 'Procurement', 'procurement',
 'Purchase order types including blanket, consignment, drop-ship and intercompany',
 array['erp.document_type', 'erp.configure_procurement(bigint,text)'],
 'partial',
 'Document types are configuration and a tenant can define any of these, but '
 'only the standard purchase order is installed and none of the four has '
 'behaviour of its own — a blanket order that does not call off is a purchase '
 'order with a different name.'),
('5.3.receipt_tolerance', '5.3', 'Procurement', 'procurement',
 'Receipt with tolerance rules and quality routing',
 array['erp.receipt_tolerance', 'erp.check_receipt_tolerance(uuid,uuid,numeric,numeric)',
       'erp.receive_against(uuid,uuid,numeric,uuid)'],
 'built', null),
('5.3.three_way_match', '5.3', 'Procurement', 'procurement',
 'Three-way matching with configurable tolerances and an exception workbench',
 array['erp.match_tolerance', 'erp.match_exception', 'erp.match_three_way(uuid)',
       'erp.match_exception_workbench()', 'erp.invoice_against(uuid,uuid,numeric,bigint)'],
 'built', null),
('5.3.grni', '5.3', 'Procurement', 'procurement',
 'Goods-received-not-invoiced control with ageing and reconciliation',
 array['erp.grni_report()', 'erp.grni_reconciliation()'],
 'built', null),
('5.3.landed_cost', '5.3', 'Procurement', 'procurement',
 'Landed cost capture and allocation',
 array['erp.landed_cost', 'erp.allocate_landed_cost(uuid)',
       'erp.add_cost_to_stock(uuid,uuid,numeric,bigint)'],
 'built', null),

-- 5.4 ------------------------------------------------------------------------
('5.4.demand_cleansing', '5.4', 'Supply chain planning', 'planning',
 'Demand history cleansing',
 array['erp.demand_history(uuid,uuid,integer,text)',
       'erp.cleansed_demand(uuid,uuid,integer,text,numeric)'],
 'built', null),
('5.4.statistical_forecasting', '5.4', 'Supply chain planning', 'planning',
 'Statistical forecasting with model selection, seasonality and event adjustment',
 array['erp.fit_forecast(numeric[],erp.forecast_method,integer,numeric,integer)',
       'erp.select_forecast_method(numeric[])', 'erp.run_forecast(text,integer,integer)',
       'erp.forecast_model_choice'],
 'partial',
 'Model selection is measured and recorded. Seasonality is not fitted: it needs '
 'at least two full cycles of history and claiming it on less would be a fit to '
 'noise. Event adjustment is manual through forecast_line.adjustment_reason.'),
('5.4.consensus_forecast', '5.4', 'Supply chain planning', 'planning',
 'Consensus forecasting with versioning and sign-off',
 array['erp.forecast_version', 'erp.sign_off_forecast(uuid,text)'],
 'built', null),
('5.4.forecast_accuracy', '5.4', 'Supply chain planning', 'planning',
 'Forecast accuracy measurement driving model reselection',
 array['erp.forecast_accuracy', 'erp.measure_forecast_accuracy(uuid)',
       'erp.select_forecast_method(numeric[])'],
 'built', null),
('5.4.inventory_policy', '5.4', 'Supply chain planning', 'planning',
 'Inventory policy calculation (safety stock, reorder point, order-up-to, economic order quantity with rounding)',
 array['erp.calculate_policy(uuid,uuid,bigint,numeric)',
       'erp.apply_calculated_policy(uuid,uuid)', 'erp.service_level_z(numeric)'],
 'built', null),
('5.4.replenishment', '5.4', 'Supply chain planning', 'planning',
 'Replenishment suggestion',
 array['erp.run_planning(uuid,integer,uuid)', 'erp.planned_order'],
 'built', null),
('5.4.drp', '5.4', 'Supply chain planning', 'planning',
 'Distribution requirements planning across sites, including redistribution driven by expiry risk',
 array['erp.suggest_redistribution(integer)'],
 'built', null),
('5.4.mrp', '5.4', 'Supply chain planning', 'planning',
 'Material requirements planning with time-phased explosion, lot sizing, time fences and pegging',
 array['erp.run_planning(uuid,integer,uuid)', 'erp.planned_order_peg',
       'erp.scheduled_supply(uuid,uuid,date,date)', 'erp.scheduled_demand(uuid,uuid,date,date,uuid)'],
 'partial',
 'Time phasing, lot sizing, time fences and pegging are built and the run is '
 'driven by forecast and firm demand. Multi-level explosion through the bill '
 'is not: a planned order for a made item does not yet raise dependent demand '
 'for its components, which erp.raise_works_order() does only once the order '
 'exists.'),
('5.4.planner_workbench', '5.4', 'Supply chain planning', 'planning',
 'Exception-driven planner workbench',
 array['erp.planning_exception', 'erp.planner_workbench(uuid)'],
 'built', null),
('5.4.supply_demand', '5.4', 'Supply chain planning', 'planning',
 'Supply and demand reconciliation with scenario comparison',
 array['erp.supply_demand_position(uuid,uuid,integer)'],
 'partial',
 'The reconciliation is built and is the projection the run itself used. '
 'Scenario comparison is not: comparing two plans means keeping two, and the '
 'planning run currently replaces rather than versions its output.'),

-- 5.5 ------------------------------------------------------------------------
('5.5.structures_change_control', '5.5', 'Production', 'production',
 'Product structures and routings with engineering change control',
 array['erp.bom', 'erp.routing', 'erp.guard_bom_change()'],
 'built', null),
('5.5.works_orders', '5.5', 'Production', 'production',
 'Works orders of multiple types including assembly, kitting, rework and repackaging',
 array['erp.works_order', 'erp.raise_works_order(uuid,uuid,numeric,erp.works_order_kind,date)'],
 'built', null),
('5.5.material_availability', '5.5', 'Production', 'production',
 'Material availability checking and commitment',
 array['erp.works_order_availability(uuid)', 'erp.release_works_order(uuid,boolean)'],
 'built', null),
('5.5.component_issue', '5.5', 'Production', 'production',
 'Component issue by backflush, manual or scanned confirmation with policy-driven batch selection',
 array['erp.issue_to_works_order(uuid,uuid,numeric,uuid,uuid)',
       'erp.select_batch_for_issue(uuid,uuid)'],
 'built', null),
('5.5.execution_capture', '5.5', 'Production', 'production',
 'Execution progress, scrap and time capture',
 array['erp.book_operation_time(uuid,integer,numeric,numeric,numeric)',
       'erp.works_order_operation', 'erp.production_event'],
 'built', null),
('5.5.fg_receipt', '5.5', 'Production', 'production',
 'Finished goods receipt with batch creation and derived attributes',
 array['erp.receive_works_order_output(uuid,numeric,text,uuid)'],
 'built', null),
('5.5.batch_records', '5.5', 'Production', 'production',
 'Electronic batch records assembled from execution events',
 array['erp.batch_record(uuid)', 'erp.production_event'],
 'built', null),
('5.5.cost_roll_up', '5.5', 'Production', 'production',
 'Standard cost roll-up and actual cost capture with variance analysis',
 array['erp.roll_up_standard_cost(uuid,uuid,integer)', 'erp.works_order_variance(uuid)',
       'erp.close_works_order(uuid)'],
 'built', null),

-- 5.6 ------------------------------------------------------------------------
('5.6.order_capture', '5.6', 'Sales and order management', 'sales',
 'Order capture across manual, automated-intake and intercompany channels',
 array['erp.open_document(text,uuid,uuid,uuid,text,date,character)', 'erp.command'],
 'partial',
 'Manual capture is built and B8''s gateway can accept an inbound order as a '
 'command. Intercompany capture — an order in one entity raising a purchase in '
 'another — is not, and would need the two documents linked as one event.'),
('5.6.quotation', '5.6', 'Sales and order management', 'sales',
 'Quotation with validity, versioning and discount approval',
 array['erp.configure_sales(numeric,text)', 'erp.transition_document(uuid,text,text)'],
 'built', null),
('5.6.pricing', '5.6', 'Sales and order management', 'sales',
 'Pricing with lists, contracts, promotions and margin control',
 array['erp.resolve_price(uuid,uuid,numeric,date,uuid)', 'erp.check_margin(uuid,uuid,bigint,text)',
       'erp.pricing_policy', 'erp.price_document_line(uuid)'],
 'built', null),
('5.6.credit', '5.6', 'Sales and order management', 'sales',
 'Credit checking and hold management',
 array['erp.credit_position(uuid)', 'erp.check_release_to_fulfilment(uuid)',
       'erp.release_credit_hold(uuid,text)'],
 'built', null),
('5.6.availability_promise', '5.6', 'Sales and order management', 'sales',
 'Availability checking and promise dating',
 array['erp.available_to_promise(uuid,uuid,date)', 'erp.promise_date(uuid,uuid,numeric,integer)'],
 'built', null),
('5.6.allocation', '5.6', 'Sales and order management', 'sales',
 'Two-stage allocation with configurable location scope and batch policy, with unmet detailed allocation classified by cause and raising internal replenishment rather than silent shortage',
 array['erp.reserve_for_line(uuid,text)', 'erp.commit_allocation(uuid,uuid,uuid)',
       'erp.allocation', 'erp.allocation_line'],
 'built', null),
('5.6.amendment_cutoff', '5.6', 'Sales and order management', 'sales',
 'Amendment and cancellation rules with explicit cut-off behaviour',
 array['erp.amendment_allowed(uuid)', 'erp.amend_document_line(uuid,numeric,text)'],
 'built', null),
('5.6.release_sequencing', '5.6', 'Sales and order management', 'sales',
 'Release to fulfilment with configurable sequencing',
 array['erp.check_release_to_fulfilment(uuid)'],
 'partial',
 'Release is gated on credit and on the lifecycle. Configurable sequencing — '
 'which orders are released first when there is not enough to go round — is '
 'not built, and would need a priority rule set over the allocation queue.'),
('5.6.delivery_documents', '5.6', 'Sales and order management', 'sales',
 'Delivery documents with part-delivery and consolidation',
 array['erp.plan_shipment(uuid,uuid[],date)', 'erp.shipment', 'erp.shipment_line'],
 'built', null),
('5.6.invoicing', '5.6', 'Sales and order management', 'sales',
 'Invoicing derived from validated delivery with role separation enforced',
 array['erp.invoice_from_delivery(uuid,boolean)'],
 'built', null),
('5.6.returns', '5.6', 'Sales and order management', 'sales',
 'Returns, credits and complaint handling',
 array['erp.customer_return', 'erp.raise_customer_return(uuid,text,text,text)',
       'erp.return_reason_analysis(integer)', 'erp.quality_event'],
 'built', null),

-- 5.7 ------------------------------------------------------------------------
('5.7.chart_ledgers', '5.7', 'Finance', 'finance',
 'Chart of accounts and parallel ledgers',
 array['erp.account', 'erp.ledger', 'erp.configure_finance(integer,character)'],
 'built', null),
('5.7.fiscal_calendar', '5.7', 'Finance', 'finance',
 'Fiscal calendars and period control',
 array['erp.fiscal_period', 'erp.check_period_open()', 'erp.reopen_period(uuid,text)'],
 'built', null),
('5.7.posting_rules', '5.7', 'Finance', 'finance',
 'Declarative posting rules from operational events',
 array['erp.posting_rule', 'erp.post_document_finance(uuid)',
       'erp.assert_posting_rule_balances(text,integer)'],
 'built', null),
('5.7.dimensions', '5.7', 'Finance', 'finance',
 'Analytical dimensions with derivation, validation and permitted-combination rules',
 array['erp.dimension', 'erp.dimension_value', 'erp.dimension_combination_rule',
       'erp.check_journal_line_posting()'],
 'partial',
 'Dimensions are declared on the journal line and accounts can require them, '
 'which the posting trigger enforces. Derivation from the source event and the '
 'permitted-combination rules are configuration that nothing evaluates yet.'),
('5.7.accounts_payable', '5.7', 'Finance', 'finance',
 'Accounts payable including non-purchase-order approval and payment proposal',
 array['erp.payment_proposal', 'erp.propose_payment_run(date,character,interval)',
       'erp.approve_payment_run(uuid)'],
 'built', null),
('5.7.accounts_receivable', '5.7', 'Finance', 'finance',
 'Accounts receivable including settlement reconciliation for prepaid channels, cash application, ageing and dunning',
 array['erp.receivables_ageing(date)', 'erp.dunning_policy', 'erp.dunning_worklist(text)',
       'erp.apply_cash(uuid,bigint,character,text)'],
 'partial',
 'Cash application, ageing and dunning are built. Settlement reconciliation for '
 'prepaid channels is not: it needs a payment-service statement to reconcile '
 'against, which is an integration this product does not have.'),
('5.7.inventory_accounting', '5.7', 'Finance', 'finance',
 'Inventory accounting including accrual, variance, revaluation and provisioning',
 array['erp.post_document_finance(uuid)', 'erp.grni_report()',
       'erp.works_order_variance(uuid)', 'erp.revaluation_report(date)'],
 'partial',
 'Accrual through goods-received-not-invoiced, purchase price and production '
 'variances, and currency revaluation are built. Provisioning for slow-moving '
 'and obsolete stock is not, though erp.stock_ageing_report() is the input it '
 'would need.'),
('5.7.fixed_assets', '5.7', 'Finance', 'finance',
 'Fixed assets',
 array['erp.fixed_asset', 'erp.depreciation_to_date(uuid,date)',
       'erp.fixed_asset_register(date)'],
 'built', null),
('5.7.tax', '5.7', 'Finance', 'finance',
 'Tax determination and statutory tax reporting per jurisdiction',
 array['erp.determine_tax(uuid)', 'erp.tax_report(date,date,uuid)',
       'erp.tax_determination', 'erp.configure_tax(character,numeric)'],
 'built', null),
('5.7.intercompany', '5.7', 'Finance', 'finance',
 'Intercompany matching and elimination',
 array['erp.intercompany_position()'],
 'partial',
 'Matching is built: the report shows where two entities of one tenant disagree '
 'about what they owe each other. Elimination on consolidation is not, and '
 'needs a consolidation ledger this product does not yet have.'),
('5.7.multi_currency', '5.7', 'Finance', 'finance',
 'Multi-currency with revaluation and translation',
 array['erp.exchange_rate', 'erp.rate_on(character,character,date,text)',
       'erp.revaluation_report(date)'],
 'built', null),
('5.7.period_close', '5.7', 'Finance', 'finance',
 'Period close with dependency-tracked tasks and blocking reconciliation checks',
 array['erp.close_task_template', 'erp.close_task', 'erp.open_period_close(uuid)',
       'erp.complete_close_task(uuid,text)', 'erp.close_period(uuid)', 'erp.close_status(uuid)'],
 'built', null),
('5.7.statutory_reporting', '5.7', 'Finance', 'finance',
 'Statutory and management reporting with drill-down from any figure to the originating event',
 array['erp.explain_posting(uuid)', 'public.erp_trial_balance()', 'erp.figure_lineage(text,date)'],
 'built', null),

-- 5.8 ------------------------------------------------------------------------
('5.8.inspection_sampling', '5.8', 'Quality, compliance and traceability', 'quality',
 'Inspection plans and sampling',
 array['erp.inspection_plan', 'erp.sample_size(jsonb,numeric)',
       'erp.raise_inspection(uuid,uuid,numeric,uuid,uuid,text)',
       'erp.record_inspection_result(uuid,text,numeric,text,text)',
       'erp.disposition_inspection(uuid,erp.disposition,text)'],
 'built', null),
('5.8.quarantine_release', '5.8', 'Quality, compliance and traceability', 'quality',
 'Quarantine control with authorised release',
 array['erp.release_batch(uuid,uuid,text,text,uuid)', 'erp.release_record'],
 'built', null),
('5.8.deviations', '5.8', 'Quality, compliance and traceability', 'quality',
 'Deviation, non-conformance and corrective action management',
 array['erp.quality_event', 'erp.raise_quality_event(erp.quality_event_kind,text,text,uuid,uuid,uuid,uuid,uuid,interval)',
       'erp.close_quality_event(uuid,text,text,text)'],
 'built', null),
('5.8.excursions', '5.8', 'Quality, compliance and traceability', 'quality',
 'Condition excursion handling with batch impact assessment',
 array['erp.assess_excursion_impact(uuid,uuid,timestamptz,timestamptz)'],
 'built', null),
('5.8.recall', '5.8', 'Quality, compliance and traceability', 'quality',
 'Recall management with impacted-despatch generation, action logging, quantity reconciliation and evidence export',
 array['erp.recall', 'erp.raise_recall(text,text,text,uuid[],text)',
       'erp.capture_recall_impact(uuid)', 'erp.log_recall_action(uuid,text,uuid,bigint,numeric,text,text)',
       'erp.recall_reconciliation(uuid)', 'erp.recall_evidence(uuid)'],
 'built', null),
('5.8.recall_readiness', '5.8', 'Quality, compliance and traceability', 'quality',
 'Continuous recall-readiness measurement against configurable regulatory clocks',
 array['erp.regulatory_clock', 'erp.recall_readiness(uuid)'],
 'built', null),
('5.8.audit_export', '5.8', 'Quality, compliance and traceability', 'quality',
 'Audit trail export by object, period or batch',
 array['erp.batch_audit_export(uuid)', 'erp.audit_entry'],
 'built', null),

-- 5.9 ------------------------------------------------------------------------
('5.9.shipment_planning', '5.9', 'Logistics', 'logistics',
 'Shipment planning and consolidation',
 array['erp.shipment', 'erp.shipment_line', 'erp.plan_shipment(uuid,uuid[],date)'],
 'built', null),
('5.9.carrier_selection', '5.9', 'Logistics', 'logistics',
 'Carrier selection by cost and service rules',
 array['erp.carrier', 'erp.select_carrier(uuid,date)', 'erp.book_shipment(uuid,text,text,bigint)'],
 'built', null),
('5.9.carrier_integration', '5.9', 'Logistics', 'logistics',
 'Carrier integration for labelling, tracking and proof of delivery',
 array['erp.record_proof_of_delivery(uuid,timestamptz,text,text)', 'erp.external_system'],
 'partial',
 'Proof of delivery and a tracking reference are captured, and B8''s gateway '
 'can carry messages to a carrier. Labelling is not built: it needs a document '
 'rendering surface this product does not have.'),
('5.9.freight_cost', '5.9', 'Logistics', 'logistics',
 'Freight cost capture and allocation',
 array['erp.book_shipment(uuid,text,text,bigint)', 'erp.shipment_line'],
 'built', null),
('5.9.customs', '5.9', 'Logistics', 'logistics',
 'Customs and cross-border documentation',
 array['erp.shipment'],
 'absent',
 'Only a customs reference field exists. Cross-border documentation needs '
 'commodity codes on items, an origin declaration and a document template per '
 'jurisdiction, none of which is built — and a customs declaration that is '
 'nearly right is worse than none.'),
('5.9.delivery_performance', '5.9', 'Logistics', 'logistics',
 'Delivery performance analysis',
 array['erp.delivery_performance(integer)'],
 'built', null),

-- 5.10 -----------------------------------------------------------------------
('5.10.report_catalogue', '5.10', 'Reporting and analytics', 'reporting',
 'Governed report catalogue by domain',
 array['erp.report', 'erp.governed_view', 'erp.assert_governed_views_are_safe()'],
 'built', null),
('5.10.self_serve', '5.10', 'Reporting and analytics', 'reporting',
 'Role- and scope-limited self-serve access with drill-down and export',
 array['erp.governed_view', 'erp.figure_lineage(text,date)'],
 'built', null),
('5.10.kpi_framework', '5.10', 'Reporting and analytics', 'reporting',
 'Centrally defined KPI framework so a metric has one calculation',
 array['erp.kpi', 'erp.kpi_version'],
 'built', null),
('5.10.scheduled_distribution', '5.10', 'Reporting and analytics', 'reporting',
 'Scheduled distribution and assembled figure packs',
 array['erp.job', 'erp.job_run', 'erp.notification_template'],
 'partial',
 'The scheduler can run a report job and the notification templates exist. '
 'Assembling several reports into one pack is not built, and needs a document '
 'composition surface this product does not have.'),
('5.10.natural_language', '5.10', 'Reporting and analytics', 'reporting',
 'Natural-language read-only querying over those views',
 array['erp.governed_view', 'erp_ai.proposal'],
 'partial',
 'The governed views and the intelligence boundary that keeps a model read-only '
 'are built and asserted. The natural-language surface itself is not: it is an '
 'application concern, and the schema''s job was to make it safe to build.'),
('5.10.traceability', '5.10', 'Reporting and analytics', 'reporting',
 'Full traceability from any reported figure to its source event',
 array['erp.figure_lineage(text,date)', 'erp.explain_posting(uuid)', 'erp.event'],
 'built', null),

-- 5.11 -----------------------------------------------------------------------
('5.11.user_administration', '5.11', 'Administration', 'administration',
 'User, role and permission administration with request and approval workflow',
 array['erp.app_user', 'erp.role', 'erp.role_permission', 'erp.grant_role(uuid,text,uuid,uuid,text,date,date)',
       'erp.invite_principal(text,text,interval)'],
 'built', null),
('5.11.sod', '5.11', 'Administration', 'administration',
 'Segregation-of-duties checking and access review packs',
 array['erp.sod_rule', 'erp.sod_conflict', 'erp.access_review', 'erp.access_review_item'],
 'built', null),
('5.11.job_management', '5.11', 'Administration', 'administration',
 'Scheduled job management with evidence',
 array['erp.job', 'erp.job_run', 'erp.job_health()', 'erp.silent_jobs()'],
 'built', null),
('5.11.configuration_promotion', '5.11', 'Administration', 'administration',
 'Configuration management, promotion and rollback',
 array['erp.change_set', 'erp.promote_change_set(uuid,text[],boolean)',
       'erp.rollback_to_snapshot(uuid,text)', 'erp.apply_change_set_item(uuid)'],
 'built', null),
('5.11.environments', '5.11', 'Administration', 'administration',
 'Environment management',
 array['erp.environment', 'erp.environment_manifest', 'erp.guard_live_configuration()'],
 'built', null),
('5.11.integration_monitoring', '5.11', 'Administration', 'administration',
 'Integration monitoring with replay',
 array['erp.integration_health()', 'erp.integration_backlog(integer)',
       'erp.integration_message', 'erp.integration_message_attempt'],
 'built', null)
on conflict (code) do update
  set requirement = excluded.requirement,
      artefacts = excluded.artefacts,
      status = excluded.status,
      gap = excluded.gap;

-- -----------------------------------------------------------------------------
-- The assertion
--
-- Every artefact a capability claims must exist. That is the whole mechanism,
-- and it is enough: a register whose claims are checked on every build cannot
-- quietly become a description of what the product used to do.
-- -----------------------------------------------------------------------------

create or replace function erp.part5_coverage_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- A named function that does not exist.
  select 'a capability claims a function that does not exist',
         c.code, a.artefact
    from erp_ref.part5_capability c
    cross join lateral unnest(c.artefacts) a(artefact)
   where a.artefact like '%(%'
     and to_regprocedure(a.artefact) is null
  union all
  -- A named table or view that does not exist. Anything without brackets is
  -- read as a relation.
  select 'a capability claims a table that does not exist',
         c.code, a.artefact
    from erp_ref.part5_capability c
    cross join lateral unnest(c.artefacts) a(artefact)
   where a.artefact not like '%(%'
     and to_regclass(a.artefact) is null
  union all
  -- A capability that claims nothing is a row in a register and not a
  -- capability.
  select 'a capability names no artefact at all',
         c.code, c.requirement
    from erp_ref.part5_capability c
   where coalesce(array_length(c.artefacts, 1), 0) = 0
  union all
  -- Every module the product declares should appear. A section of Part 5 with
  -- no capabilities registered is one somebody forgot to write down, which is
  -- exactly the failure this register exists to prevent.
  select 'a module has no registered capabilities',
         m.code, 'Part 5 names this module and nothing claims to deliver any of it'
    from erp_ref.module m
   where not exists (select 1 from erp_ref.part5_capability c
                      where c.module_code = m.code)
$$;

create or replace function erp.assert_part5_coverage()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer; v_detail text;
  v_built integer; v_partial integer; v_absent integer;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail from erp.part5_coverage_report();

  if v_count > 0 then
    raise exception 'ERPWARE_PART5_COVERAGE_BROKEN: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;

  select count(*) filter (where status = 'built'),
         count(*) filter (where status = 'partial'),
         count(*) filter (where status = 'absent')
    into v_built, v_partial, v_absent
    from erp_ref.part5_capability;

  -- The count is reported, not asserted. A minimum here would create pressure
  -- to mark something built to keep the number up, which is precisely the
  -- pressure this register exists to resist.
  return format('part 5: %s built, %s partial, %s absent, of %s capabilities',
                v_built, v_partial, v_absent, v_built + v_partial + v_absent);
end;
$$;

comment on function erp.assert_part5_coverage() is
  'Checks that every artefact the register claims actually exists. Reports the '
  'built/partial/absent counts rather than asserting a minimum: a floor here '
  'would create pressure to mark something built to keep the number up.';

create or replace function erp.part5_coverage(p_section text default null)
returns table (section text, section_name text, capability text,
               requirement text, status text, gap text, artefacts text[])
language sql
stable
security invoker
set search_path = ''
as $$
  select c.section, c.section_name, c.code, c.requirement, c.status, c.gap,
         c.artefacts
    from erp_ref.part5_capability c
   where p_section is null or c.section = p_section
   order by string_to_array(c.section, '.')::integer[], c.code
$$;

create or replace function erp.part5_summary()
returns table (section text, section_name text, built bigint, partial bigint,
               absent bigint, total bigint, built_pct numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  select c.section, c.section_name,
         count(*) filter (where c.status = 'built'),
         count(*) filter (where c.status = 'partial'),
         count(*) filter (where c.status = 'absent'),
         count(*),
         round(100.0 * count(*) filter (where c.status = 'built') / count(*), 1)
    from erp_ref.part5_capability c
   group by c.section, c.section_name
   order by string_to_array(c.section, '.')::integer[]
$$;

create or replace function public.erp_part5_coverage(p_section text default null)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb)
        from erp.part5_coverage(p_section) c $$;

create or replace function public.erp_part5_summary()
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb)
        from erp.part5_summary() s $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_part5_coverage(text)', 'public.erp_part5_summary()'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

-- The register is product content: it describes what the product does, which
-- is the same for every tenant. Registering it makes the generators give it
-- the same read-only-to-tenants policy every other reference table has.
select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_part5_coverage();
select erp.assert_public_api_safe();
select erp.assert_resource_coverage('en');
select erp.assert_isolation();
