-- =============================================================================
-- Starter Content Packs — the base pack, part one: §3, §4 and §6
--
-- "The values every ERP needs on day one, which otherwise get invented ad hoc
-- by whoever hits the screen first."
--
-- Every row here is a change-set item, so applying the pack is a promotion with
-- a preview, a diff and a rollback rather than an insert nobody can undo. Every
-- row also carries its provenance, because §12 makes neutrality a release gate
-- and a gate you cannot check is a promise.
--
-- One structural point worth stating once. §3.4 says approval band thresholds
-- are "left blank and promotion refused until they are set, so the decision
-- happens at onboarding rather than leaving a chain that approves everything
-- silently". That is exactly erp_ref.pack_item.is_decision, and it is the
-- clearest illustration of why the decision mechanism exists: a band with a
-- guessed threshold is worse than no band, because it looks configured.
-- =============================================================================

insert into erp_ref.content_pack
  (code, name, description, kind, version, provenance, seq) values
  ('base', 'Base pack',
   'Departments, roles, segregation of duties, calendars, vocabularies and '
   'reason codes — the content every organisation needs before it can do '
   'anything at all.',
   'base', '1.0.0',
   'Starter Content Packs §3, §4, §5, §6, §7, §8 and §9. Departments and roles '
   'follow the functional split common to mid-market distribution and '
   'manufacturing; units of measure are UNECE Recommendation 20; Incoterms are '
   'the 2020 edition; segregation-of-duties conflicts follow ISACA''s standard '
   'pairs. No value is taken from any organisation.', 10)
on conflict (code) do update set
  name = excluded.name, description = excluded.description,
  version = excluded.version, provenance = excluded.provenance;

-- ── §3.1 Departments ─────────────────────────────────────────────────────────
--
-- "Each with a suggested cost centre code and an empty approval band set."
-- Suggested, so the cost centre is in the payload and an organisation that
-- numbers its cost centres differently overrides one field rather than
-- rebuilding the list.

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, provenance, seq)
select 'base', 'department', d.code,
       jsonb_build_object('code', d.code, 'name', d.name,
                          'default_cost_centre', d.cost_centre),
       'Starter Content Packs §3.1. Cost centre codes are a decimal ladder in '
       'hundreds, which is conventional and leaves room between them.',
       d.seq
  from (values
    ('EXEC',   'Executive',                 'CC100', 10),
    ('FIN',    'Finance',                   'CC200', 20),
    ('PROC',   'Procurement',               'CC300', 30),
    ('PLAN',   'Supply Chain and Planning', 'CC400', 40),
    ('OPS',    'Operations',                'CC500', 50),
    ('WHSE',   'Warehouse',                 'CC510', 60),
    ('PROD',   'Production',                'CC520', 70),
    ('QUAL',   'Quality',                   'CC530', 80),
    ('SALES',  'Sales',                     'CC600', 90),
    ('CS',     'Customer Service',          'CC610', 100),
    ('LOG',    'Logistics',                 'CC620', 110),
    ('FAC',    'Facilities',                'CC700', 120),
    ('IT',     'Information Technology',    'CC800', 130),
    ('PEOPLE', 'People',                    'CC900', 140)
  ) d(code, name, cost_centre, seq)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, provenance = excluded.provenance, seq = excluded.seq;

-- ── §3.2 Role templates ──────────────────────────────────────────────────────
--
-- Eighteen roles, each a set of grants from erp_ref.permission. The grants are
-- the whole content: a role called "Buyer" that can do everything is not a
-- template, it is a label.
--
-- Two are deliberately unlike the rest. The auditor is read-only across every
-- module, which is what makes it safe to hand out. The integration principal
-- is a service account and holds exactly the two permissions a machine needs —
-- if a person is using it, that is a finding.

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, provenance, seq)
select 'base', 'role', r.code,
       jsonb_build_object(
         'code', r.code, 'name', r.name, 'from_template', 'base-1.0.0',
         'permissions', (select jsonb_agg(jsonb_build_object('permission', pc))
                           from unnest(r.perms) pc)),
       r.why, r.seq
  from (values
    ('administrator', 'Administrator',
     array['administration.read','administration.configure','administration.roles',
           'administration.users','administration.audit_read','administration.promote',
           'administration.jobs','administration.integrate'],
     'Starter Content Packs §3.2. Administration only: an administrator who '
     'can also post journals defeats every segregation rule in §3.3.', 10),
    ('finance_manager', 'Finance manager',
     array['finance.read','finance.post','finance.configure','finance.close_period',
           'finance.approve_payment','reporting.read','reporting.export',
           'master_data.read','procurement.read','sales.read'],
     'Starter Content Packs §3.2. Holds close_period but not reopen_period: '
     'reopening a closed period is §6''s own reason category and belongs above '
     'the person who closed it.', 20),
    ('finance_clerk', 'Finance clerk',
     array['finance.read','finance.post','procurement.match','procurement.read',
           'sales.invoice','sales.read','master_data.read','reporting.read'],
     'Starter Content Packs §3.2. Posts and matches; approves nothing.', 30),
    ('buyer', 'Buyer',
     array['procurement.read','procurement.requisition','procurement.order',
           'master_data.read','planning.read','inventory.read','reporting.read'],
     'Starter Content Packs §3.2. Raises and orders; §3.3''s first conflict is '
     'that the same person must not also approve.', 40),
    ('procurement_manager', 'Procurement manager',
     array['procurement.read','procurement.requisition','procurement.order',
           'procurement.approve','master_data.read','master_data.write',
           'planning.read','reporting.read'],
     'Starter Content Packs §3.2. Approves, and §3.3 refuses receiving against '
     'what this role approved.', 50),
    ('planner', 'Planner',
     array['planning.read','planning.run','planning.firm','planning.forecast',
           'inventory.read','procurement.read','production.read','master_data.read',
           'reporting.read'],
     'Starter Content Packs §3.2.', 60),
    ('production_supervisor', 'Production supervisor',
     array['production.read','production.order','production.release','production.execute',
           'inventory.read','inventory.move','planning.read','quality.read',
           'master_data.read','reporting.read'],
     'Starter Content Packs §3.2.', 70),
    ('production_operator', 'Production operator',
     array['production.read','production.execute','inventory.read','inventory.move'],
     'Starter Content Packs §3.2. Executes what has already been released; the '
     'release is the supervisor''s.', 80),
    ('warehouse_manager', 'Warehouse manager',
     array['inventory.read','inventory.move','inventory.count','inventory.adjust',
           'inventory.write_off','logistics.read','logistics.plan','logistics.despatch',
           'procurement.receive','master_data.read','reporting.read'],
     'Starter Content Packs §3.2. Holds adjust and write_off; §3.3''s seventh '
     'conflict refuses the same person approving the adjustment.', 90),
    ('warehouse_operative', 'Warehouse operative',
     array['inventory.read','inventory.move','inventory.count','procurement.receive',
           'logistics.read','logistics.despatch'],
     'Starter Content Packs §3.2. Counts but does not adjust: a variance is a '
     'finding for somebody else to accept.', 100),
    ('quality_manager', 'Quality manager',
     array['quality.read','quality.inspect','quality.disposition','quality.release_batch',
           'quality.recall','inventory.read','production.read','master_data.read',
           'reporting.read'],
     'Starter Content Packs §3.2.', 110),
    ('quality_inspector', 'Quality inspector',
     array['quality.read','quality.inspect','inventory.read','production.read',
           'master_data.read'],
     'Starter Content Packs §3.2. Inspects and records; the disposition and the '
     'release are the manager''s or the Responsible Person''s.', 120),
    ('responsible_person', 'Responsible Person',
     array['quality.read','quality.release_batch','quality.recall','quality.disposition',
           'inventory.read','logistics.read','reporting.read','administration.audit_read'],
     'Starter Content Packs §3.2, and Terminology §3, which says the UK '
     'regulatory titles are not to be softened. Named authority for batch '
     'release and for a recall, which is why it also reads the audit trail.', 130),
    ('sales_manager', 'Sales manager',
     array['sales.read','sales.order','sales.price','sales.discount_approve',
           'sales.credit_release','sales.invoice','master_data.read','inventory.read',
           'reporting.read'],
     'Starter Content Packs §3.2.', 140),
    ('sales_administrator', 'Sales administrator',
     array['sales.read','sales.order','sales.invoice','master_data.read',
           'inventory.read','logistics.read'],
     'Starter Content Packs §3.2. Takes orders; the discount and the credit '
     'release are the manager''s.', 150),
    ('customer_service', 'Customer service',
     array['sales.read','sales.order','logistics.read','inventory.read',
           'master_data.read','quality.read'],
     'Starter Content Packs §3.2.', 160),
    ('auditor', 'Auditor',
     array['administration.read','administration.audit_read','finance.read',
           'procurement.read','sales.read','inventory.read','production.read',
           'quality.read','planning.read','logistics.read','master_data.read',
           'reporting.read','reporting.export'],
     'Starter Content Packs §3.2. Every read permission and no write. That is '
     'what makes it safe to grant to somebody outside the organisation.', 170),
    ('integration', 'Integration service account',
     array['administration.integrate','administration.jobs'],
     'Starter Content Packs §3.2, and Terminology §2, which calls the '
     'non-human case a service account. Exactly what a machine needs; a person '
     'signed in as this is a finding.', 180)
  ) r(code, name, perms, why, seq)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, provenance = excluded.provenance, seq = excluded.seq;

-- ── §3.3 Segregation-of-duties rules ─────────────────────────────────────────
--
-- "Pre-declared conflicts, each switchable." Eight of them, and each names two
-- permission sets that must not meet in one person. erp.upsert_sod_rule()
-- refuses a rule naming a permission that does not exist, because a rule that
-- can never fire is indistinguishable from no rule.
--
-- Severity is the judgement: prohibited where the pairing is fraud by
-- construction, material where it is a control weakness somebody may accept
-- with a compensating control.

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, provenance, seq)
select 'base', 'sod_rule', s.code,
       jsonb_build_object('code', s.code, 'name', s.name,
                          'permissions_a', s.a, 'permissions_b', s.b,
                          'severity', s.severity, 'description', s.description,
                          'mitigation', s.mitigation),
       'Starter Content Packs §3.3. The pairing is standard in ISACA''s '
       'segregation-of-duties guidance; the severity is this product''s '
       'judgement and an organisation may lower it with a written mitigation.',
       s.seq
  from (values
    ('RAISE_APPROVE_REQ', 'Raise and approve a requisition',
     'procurement.requisition', 'procurement.approve', 'prohibited',
     'One person raising a requisition and approving it is a purchase nobody else saw.',
     'Split across two people, or route the raiser''s own requisitions to a band above them.',
     10),
    ('APPROVE_RECEIVE_PO', 'Approve a purchase order and receive against it',
     'procurement.approve', 'procurement.receive', 'prohibited',
     'Approving an order and confirming its receipt is a payment with no independent evidence that anything arrived.',
     'Receiving belongs with the warehouse, which is where the goods are.',
     20),
    ('DELIVER_INVOICE', 'Validate a delivery and raise its invoice',
     'logistics.despatch', 'sales.invoice', 'material',
     'Confirming a despatch and invoicing it lets one person bill for what was never sent.',
     'Acceptable in a small operation with a compensating despatch-to-invoice reconciliation.',
     30),
    ('POST_CLOSE', 'Post a journal and close the period',
     'finance.post', 'finance.close_period', 'prohibited',
     'Posting and then closing seals an entry against the review the close is for.',
     'The close belongs above the person posting.',
     40),
    ('AMEND_RELEASE_BATCH', 'Amend a batch and release it',
     'quality.disposition', 'quality.release_batch', 'prohibited',
     'Changing a batch record and releasing the batch is the finding an inspector opens with.',
     'Release is the Responsible Person''s and nobody else''s.',
     50),
    ('CREATE_PAY_SUPPLIER', 'Create a supplier and pay it',
     'master_data.write', 'finance.approve_payment', 'prohibited',
     'Creating a supplier and approving its payment is the classic route to a supplier that does not exist.',
     'Supplier creation goes through master_data.approve by a second person.',
     60),
    ('ADJUST_APPROVE_STOCK', 'Adjust stock and approve the adjustment',
     'inventory.adjust', 'inventory.write_off', 'material',
     'Adjusting and writing off in one pair of hands makes a shortfall disappear without anybody seeing it.',
     'A write-off above the count variance tolerance routes to a band.',
     70),
    ('GRANT_AND_USE', 'Grant permissions and use them',
     'administration.roles', 'finance.post', 'prohibited',
     'Somebody who can grant themselves a permission holds every permission, and no other rule here means anything.',
     'Role administration is separate from every operational permission, which is why the administrator template holds only administration.',
     80)
  ) s(code, name, a, b, severity, description, mitigation, seq)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, provenance = excluded.provenance, seq = excluded.seq;

-- ── §3.4 Approval bands — the decisions ──────────────────────────────────────
--
-- "Three bands per department with thresholds left blank and PROMOTION REFUSED
-- until they are set, so the decision happens at onboarding rather than
-- leaving a chain that approves everything silently."
--
-- Every one of these is a decision item. The pack supplies the shape — which
-- department, which document, which of the three bands, which role approves —
-- and refuses to supply the number, because a guessed threshold is worse than
-- no threshold: it looks configured.
--
-- Three departments rather than fourteen, and that is deliberate. §3.4 says
-- three bands per department; shipping forty-two blank decisions would make
-- onboarding a data-entry exercise nobody finishes. These are the three that
-- spend money — procurement, finance and sales — and the interview adds the
-- rest when an organisation says it needs them.

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, provenance, seq,
   is_decision, decision_prompt)
select 'base', 'approval_band',
       b.dept || '|' || b.object_type || '|' || b.seq::text,
       jsonb_build_object(
         'department', b.dept, 'object_type', b.object_type, 'seq', b.seq,
         'approver_role', b.role, 'currency', 'GBP',
         'lower_bound_minor', b.lower_bound,
         'escalate_after_hours', 48, 'vacancy', 'hold_and_raise'),
       'Starter Content Packs §3.4. The band structure is the pack''s; the '
       'threshold is the organisation''s, and promotion refuses without it.',
       b.seq + 100, true, b.prompt
  from (values
    ('PROC', 'requisition', 1, 'procurement_manager', 0,
     'Up to what value may a procurement manager approve a requisition alone? (in minor units, e.g. 500000 for £5,000)'),
    ('PROC', 'requisition', 2, 'finance_manager', null::bigint,
     'Above the first band, up to what value may a finance manager approve a requisition?'),
    ('PROC', 'requisition', 3, 'administrator', null,
     'Above the second band, who approves and up to what value? Leave the upper bound open for no ceiling.'),
    ('PROC', 'purchase_order', 1, 'procurement_manager', 0,
     'Up to what value may a procurement manager approve a purchase order alone?'),
    ('PROC', 'purchase_order', 2, 'finance_manager', null,
     'Above the first band, up to what value may a finance manager approve a purchase order?'),
    ('PROC', 'purchase_order', 3, 'administrator', null,
     'Above the second band, who approves a purchase order and up to what value?'),
    ('FIN', 'invoice_reference', 1, 'finance_clerk', 0,
     'Up to what value may a finance clerk approve a supplier invoice that matched within tolerance?'),
    ('FIN', 'invoice_reference', 2, 'finance_manager', null,
     'Above the first band, up to what value may a finance manager approve a supplier invoice?'),
    ('FIN', 'invoice_reference', 3, 'administrator', null,
     'Above the second band, who approves a supplier invoice and up to what value?'),
    ('SALES', 'sales_order', 1, 'sales_administrator', 0,
     'Up to what value may a sales administrator release an order held on credit?'),
    ('SALES', 'sales_order', 2, 'sales_manager', null,
     'Above the first band, up to what value may a sales manager release a held order?'),
    ('SALES', 'sales_order', 3, 'finance_manager', null,
     'Above the second band, who releases a held order and up to what value?')
  ) b(dept, object_type, seq, role, lower_bound, prompt)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, provenance = excluded.provenance,
  seq = excluded.seq, is_decision = excluded.is_decision,
  decision_prompt = excluded.decision_prompt;

-- ── §3.5 Calendars ───────────────────────────────────────────────────────────
--
-- "Standard working week, two-shift and three-shift patterns, and public
-- holiday sets for the jurisdictions of the bound legislation packs. Sites
-- inherit and override."
--
-- The three patterns ship; the public holidays do not, and that is a finding
-- rather than an omission. A holiday set belongs to a jurisdiction, and which
-- jurisdiction applies is what erp.entity_legislation_binding says — so a
-- holiday set in the base pack would be either wrong for most organisations or
-- a guess about which country they are in. It belongs in a legislation pack,
-- which is where §5 of the main specification already puts jurisdictional
-- content, and erp_ref.legislation_pack is where it would go.

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, provenance, seq)
select 'base', 'calendar', c.code,
       jsonb_build_object('code', c.code, 'name', c.name, 'timezone', 'UTC',
                          'working_days', c.days),
       c.why, c.seq
  from (values
    ('STD', 'Standard working week',
     jsonb_build_array(true, true, true, true, true, false, false),
     'Starter Content Packs §3.5. Monday to Friday, ISO 8601 week order. UTC '
     'because a calendar with a guessed timezone silently moves every due date.',
     10),
    ('SHIFT2', 'Two-shift pattern',
     jsonb_build_array(true, true, true, true, true, true, false),
     'Starter Content Packs §3.5. Six days: a two-shift operation runs the '
     'Saturday that a five-day office does not.', 20),
    ('SHIFT3', 'Three-shift pattern',
     jsonb_build_array(true, true, true, true, true, true, true),
     'Starter Content Packs §3.5. Continuous. Ageing and escalation timers '
     'read this, so a three-shift site that inherits the standard week '
     'escalates approvals it was working through.', 30)
  ) c(code, name, days, why, seq)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, provenance = excluded.provenance, seq = excluded.seq;

-- ── §4.1 Units of measure ────────────────────────────────────────────────────
--
-- Generated from erp_ref.uom rather than restated, so the pack and the
-- catalogue cannot disagree. Conversions travel on the unit that converts,
-- because the promoter's uom branch takes converts_to and factor alongside the
-- unit itself.

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, provenance, seq)
select 'base', 'uom', u.code,
       jsonb_build_object('code', u.code, 'name', u.name,
                          'uom_class', u.uom_class, 'decimals', u.decimals,
                          'is_base', u.is_base)
       || coalesce((select jsonb_build_object('converts_to', c.to_code,
                                              'factor', c.factor)
                      from erp_ref.uom_conversion c where c.from_code = u.code),
                   '{}'::jsonb),
       format('Starter Content Packs §4.1. UNECE Recommendation 20 code %s.',
              coalesce(u.unece_code, u.code)),
       -- Base unit of each family first, then the rest of that family.
       -- Ordering by erp_ref.uom.seq alone put the milligram before the
       -- kilogram, and the promotion failed on ERPWARE_UNKNOWN_UOM because
       -- the conversion travels with the unit that converts and its target
       -- did not exist yet. The catalogue's own order is for reading; this
       -- one is for applying.
       100 + row_number() over (order by u.uom_class, u.is_base desc, u.seq)
  from erp_ref.uom u
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, provenance = excluded.provenance, seq = excluded.seq;

-- ── §4.3 and §4.4 Posting classes ────────────────────────────────────────────
--
-- Terminology §2 renames these accounting codes on the product surface. The
-- kind stays posting_class in the schema and in the change-set vocabulary,
-- which is exactly the split Terminology §1 asks for.

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, provenance, seq)
select 'base', 'posting_class', pc.kind || '|' || pc.code,
       jsonb_build_object('kind', pc.kind, 'code', pc.code, 'name', pc.name,
                          'description', pc.description),
       pc.why, pc.seq
  from (values
    -- §4.3 item posting classes, twelve as listed
    ('item', 'FG',        'Finished good',
     'Complete and saleable.',
     'Starter Content Packs §4.3.', 200),
    ('item', 'SFG',       'Semi-finished good',
     'Made here and consumed here; not sold as it stands.',
     'Starter Content Packs §4.3.', 201),
    ('item', 'RAW',       'Raw material',
     'Bought to be transformed.',
     'Starter Content Packs §4.3.', 202),
    ('item', 'PACK',      'Packaging',
     'Consumed at pack-out and absorbed into the finished good.',
     'Starter Content Packs §4.3.', 203),
    ('item', 'CONS',      'Consumable',
     'Used up in operations rather than in a product.',
     'Starter Content Packs §4.3.', 204),
    ('item', 'SPARE',     'Spare part',
     'Held against a breakdown; usage is unpredictable by design.',
     'Starter Content Packs §4.3.', 205),
    ('item', 'SERVICE',   'Non-stock service',
     'Bought and sold; never held, so it never touches the stock ledger.',
     'Starter Content Packs §4.3.', 206),
    ('item', 'SAMPLE',    'Sample',
     'Issued without revenue, which is why it needs its own posting.',
     'Starter Content Packs §4.3.', 207),
    ('item', 'PROMO',     'Promotional item',
     'Despatched at nil or reduced value against a campaign.',
     'Starter Content Packs §4.3.', 208),
    ('item', 'ASSET',     'Asset held as stock',
     'Capitalised on issue rather than expensed.',
     'Starter Content Packs §4.3.', 209),
    ('item', 'CUSTOWN',   'Customer-owned material',
     'Held, not owned. It is on the balance sheet of somebody else.',
     'Starter Content Packs §4.3.', 210),
    ('item', 'CONSIGN',   'Supplier-owned consignment',
     'Held, not owned, until consumed — at which point it is bought.',
     'Starter Content Packs §4.3.', 211),
    -- §4.4 party posting classes, eleven as listed
    ('party', 'SUP_DOM',  'Domestic supplier',
     'Supplier inside the entity''s own tax jurisdiction.',
     'Starter Content Packs §4.4.', 220),
    ('party', 'SUP_EU',   'EU supplier',
     'Supplier inside the customs union, which changes the tax treatment.',
     'Starter Content Packs §4.4.', 221),
    ('party', 'SUP_ROW',  'Rest-of-world supplier',
     'Supplier outside the customs union; duty and import tax apply.',
     'Starter Content Packs §4.4.', 222),
    ('party', 'SUP_IC',   'Intercompany supplier',
     'Another entity in the same group. Its postings eliminate on consolidation.',
     'Starter Content Packs §4.4.', 223),
    ('party', 'CUST_DOM', 'Domestic customer',
     'Customer inside the entity''s own tax jurisdiction.',
     'Starter Content Packs §4.4.', 224),
    ('party', 'CUST_EU',  'EU customer',
     'Customer inside the customs union.',
     'Starter Content Packs §4.4.', 225),
    ('party', 'CUST_ROW', 'Rest-of-world customer',
     'Customer outside the customs union; export documentation applies.',
     'Starter Content Packs §4.4.', 226),
    ('party', 'CUST_IC',  'Intercompany customer',
     'Another entity in the same group.',
     'Starter Content Packs §4.4.', 227),
    ('party', 'CARRIER',  'Carrier',
     'Moves goods; bought as freight rather than as stock.',
     'Starter Content Packs §4.4.', 228),
    ('party', 'EMPLOYEE', 'Employee',
     'Expenses and advances, which post nothing like a supplier invoice.',
     'Starter Content Packs §4.4.', 229),
    ('party', 'OTHER',    'Other',
     'Anything the ten above do not cover, so that no party is unclassified — '
     '§5 refuses a default-to-suspense, and an unclassified party is how a '
     'posting reaches one.',
     'Starter Content Packs §4.4.', 230)
  ) pc(kind, code, name, description, why, seq)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, provenance = excluded.provenance, seq = excluded.seq;

-- ── §4.5 Classification axes ─────────────────────────────────────────────────
--
-- "Populated where a standard exists... Empty for the tenant: brand · product
-- family · size or strength · pack format · therapeutic or application class."
--
-- Both halves ship. The populated axes carry their values; the empty ones ship
-- as an axis with no values, which is the point — an organisation that has to
-- create the axis before it can classify anything will classify nothing.

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, provenance, seq)
select 'base', 'classification_axis', a.code,
       jsonb_build_object('code', a.code, 'name', a.name,
                          'is_mandatory', a.mandatory, 'seq', a.seq),
       a.why, a.seq + 300
  from (values
    ('PRODUCT_TYPE',  'Product type',        true,  10,
     'Starter Content Packs §4.5, populated. Mandatory because §5 refuses a '
     'default-to-suspense and product type is what determination reads first.'),
    ('STORAGE_COND',  'Storage condition',   false, 20,
     'Starter Content Packs §4.5, populated. Values are the six the section names.'),
    ('HAZARD_CLASS',  'Hazard class',        false, 30,
     'Starter Content Packs §4.5, populated. UN transport classes 1 to 9.'),
    ('ORIGIN',        'Country of origin',   false, 40,
     'Starter Content Packs §4.5, populated from ISO 3166 via erp_ref.country.'),
    ('COMMODITY',     'Commodity code',      false, 50,
     'Starter Content Packs §4.5. The structure ships; the codes are a '
     'jurisdictional tariff schedule and belong to a legislation pack.'),
    ('BRAND',         'Brand',               false, 60,
     'Starter Content Packs §4.5, empty for the tenant.'),
    ('FAMILY',        'Product family',      false, 70,
     'Starter Content Packs §4.5, empty for the tenant.'),
    ('SIZE_STRENGTH', 'Size or strength',    false, 80,
     'Starter Content Packs §4.5, empty for the tenant.'),
    ('PACK_FORMAT',   'Pack format',         false, 90,
     'Starter Content Packs §4.5, empty for the tenant.'),
    ('APPLICATION',   'Application class',   false, 100,
     'Starter Content Packs §4.5, empty for the tenant. Called therapeutic '
     'class in regulated goods, which the regulated profile pack renames.')
  ) a(code, name, mandatory, seq, why)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, provenance = excluded.provenance, seq = excluded.seq;

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, provenance, seq)
select 'base', 'classification_value', v.axis || '|' || v.code,
       jsonb_build_object('axis', v.axis, 'code', v.code, 'name', v.name,
                          'abbreviation', v.abbrev),
       v.why, v.seq + 400
  from (values
    ('STORAGE_COND', 'AMBIENT',      'Ambient',              'AMB',  10,
     'Starter Content Packs §4.5, storage condition.'),
    ('STORAGE_COND', 'COOL',         'Cool',                 'COOL', 20,
     'Starter Content Packs §4.5, storage condition.'),
    ('STORAGE_COND', 'REFRIGERATED', 'Refrigerated',         'CHIL', 30,
     'Starter Content Packs §4.5, storage condition.'),
    ('STORAGE_COND', 'FROZEN',       'Frozen',               'FRZ',  40,
     'Starter Content Packs §4.5, storage condition.'),
    ('STORAGE_COND', 'CONTROLLED',   'Controlled',           'CTRL', 50,
     'Starter Content Packs §4.5, storage condition.'),
    ('STORAGE_COND', 'HAZARDOUS',    'Hazardous',            'HAZ',  60,
     'Starter Content Packs §4.5, storage condition.'),
    ('HAZARD_CLASS', 'UN1', 'Class 1 — Explosives',                    '1',  10,
     'UN Model Regulations on the Transport of Dangerous Goods, class 1.'),
    ('HAZARD_CLASS', 'UN2', 'Class 2 — Gases',                         '2',  20,
     'UN Model Regulations, class 2.'),
    ('HAZARD_CLASS', 'UN3', 'Class 3 — Flammable liquids',             '3',  30,
     'UN Model Regulations, class 3.'),
    ('HAZARD_CLASS', 'UN4', 'Class 4 — Flammable solids',              '4',  40,
     'UN Model Regulations, class 4.'),
    ('HAZARD_CLASS', 'UN5', 'Class 5 — Oxidising substances',          '5',  50,
     'UN Model Regulations, class 5.'),
    ('HAZARD_CLASS', 'UN6', 'Class 6 — Toxic and infectious',          '6',  60,
     'UN Model Regulations, class 6.'),
    ('HAZARD_CLASS', 'UN7', 'Class 7 — Radioactive material',          '7',  70,
     'UN Model Regulations, class 7.'),
    ('HAZARD_CLASS', 'UN8', 'Class 8 — Corrosive substances',          '8',  80,
     'UN Model Regulations, class 8.'),
    ('HAZARD_CLASS', 'UN9', 'Class 9 — Miscellaneous dangerous goods', '9',  90,
     'UN Model Regulations, class 9.'),
    ('PRODUCT_TYPE', 'STOCK',    'Stock product',     'STK', 10,
     'Starter Content Packs §4.5. Held and counted.'),
    ('PRODUCT_TYPE', 'NONSTOCK', 'Non-stock product', 'NST', 20,
     'Starter Content Packs §4.5. Bought and sold without ever being held.'),
    ('PRODUCT_TYPE', 'SERVICE',  'Service',           'SVC', 30,
     'Starter Content Packs §4.5. Never touches the stock ledger.')
  ) v(axis, code, name, abbrev, seq, why)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, provenance = excluded.provenance, seq = excluded.seq;

-- Country of origin, generated from the catalogue that already holds ISO 3166
-- rather than restated. §4.5 says "populated where a standard exists", and the
-- standard is already in erp_ref.country.
insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, provenance, seq)
select 'base', 'classification_value', 'ORIGIN|' || c.code,
       jsonb_build_object('axis', 'ORIGIN', 'code', c.code, 'name', c.name,
                          'abbreviation', c.code),
       'Starter Content Packs §4.5. ISO 3166-1 alpha-2, from erp_ref.country.',
       500 + row_number() over (order by c.code)
  from erp_ref.country c where c.is_active
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, provenance = excluded.provenance, seq = excluded.seq;

-- ── §4.6 Code template ───────────────────────────────────────────────────────
--
-- "One neutral default — [type:2]-[family:3]-[sequence:5] — offered rather than
-- imposed." Offered, so it is one template and not a mandatory one.

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, provenance, seq)
values ('base', 'code_template', 'NEUTRAL',
  jsonb_build_object(
    'code', 'NEUTRAL', 'name', 'Neutral product code',
    'casing', 'upper',
    'segments', jsonb_build_array(
      jsonb_build_object('kind', 'axis', 'axis', 'PRODUCT_TYPE', 'length', 2),
      jsonb_build_object('kind', 'axis', 'axis', 'FAMILY', 'length', 3),
      jsonb_build_object('kind', 'sequence', 'length', 5))),
  'Starter Content Packs §4.6, the section''s own pattern: [type:2]-[family:3]-'
  '[sequence:5]. Offered rather than imposed — an organisation with an existing '
  'code scheme keeps it and never applies this item.',
  700)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, provenance = excluded.provenance, seq = excluded.seq;

-- ── §6 Reason codes ──────────────────────────────────────────────────────────
--
-- Generated from erp_ref.reason_code, so the pack and the catalogue cannot
-- drift. Recall and scrap reasons are gated on the capabilities that make them
-- meaningful: an organisation with recall management off has no use for a
-- RECALLED scrap reason, and §2 says content arrives switched off until wanted.

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, requires_capability, provenance, seq)
select 'base', 'reason_code', rc.category_code || '|' || rc.code,
       jsonb_build_object('category', rc.category_code, 'code', rc.code,
                          'name', rc.name,
                          'requires_note', rc.requires_note,
                          'requires_approval', rc.requires_approval,
                          'seq', rc.seq),
       case
         when rc.code = 'RECALLED' then 'recall_management'
         when rc.category_code = 'BATCH_AMENDMENT' then 'batch_control'
         when rc.code in ('EXPIRED', 'EXPIRY_WRITE_OFF', 'SHORT_DATED') then 'expiry_control'
         when rc.code = 'FAILED_INSPECTION' then 'quality_inspection'
         when rc.category_code = 'ALLOCATION_OVERRIDE' then null
         else null
       end,
       format('Starter Content Packs §6, %s.',
              (select lower(c.name) from erp_ref.reason_category c
                where c.code = rc.category_code)),
       1000 + (select c.seq from erp_ref.reason_category c
                where c.code = rc.category_code) + rc.seq
  from erp_ref.reason_code rc
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, requires_capability = excluded.requires_capability,
  provenance = excluded.provenance, seq = excluded.seq;

select erp.assert_packs_installable();
