-- Every Settings screen has a walkthrough.
--
-- The Work area says what to do next: every module page carries its process,
-- step by step, and the box where work waits is the box with the button. The
-- Settings area did not. Twenty-seven screens, each with the right forms on it,
-- and nothing on any of them saying which form comes first, what has to exist
-- before it, or whether the thing it makes has been made. A site needs a
-- company; the form refuses when there is none, and that refusal was the
-- guidance. Two people setting an organisation up abandoned things halfway
-- because nothing told them there was a halfway.
--
-- Guidance existed in three places, none of them on the screen. Every screen
-- has a help topic with ordered steps, behind the small question mark in the
-- header, and the steps are sentences nobody can act on. The first-run guide
-- on the Work home completes its steps from evidence in the organisation's own
-- tables (20260904650000), but it is per person, per role, and names six of the
-- twenty-seven screens. The Settings home says "start at the top and work
-- down" and stops there.
--
-- This is the fourth, and it is built the way the first-run guide is built,
-- because that one is right: a register of steps, an evidence function that
-- reads the organisation's own state, a door that hands the screen its steps
-- with the evidence beside them, and an assertion that holds the register to
-- it. Three differences, each deliberate:
--
--   * It is per screen and per organisation, not per person and per role. A
--     company either exists or it does not; that is not a fact about who is
--     looking. Ticks and "not for us" are recorded for the organisation.
--   * Steps carry the door they open, so the screen can open the form rather
--     than point at it, and the steps on other screens they require, so the
--     walkthrough can say "a site needs a company" before the form does.
--   * The screens themselves are in an order — erp_ref.setup_screen — which is
--     the order the Settings home already claims and nothing enforced.
--
-- 58 steps across 27 screens; 53 complete themselves. The
-- 5 that do not are reading screens ("nothing records that you
-- looked") and one staging step whose evidence lives in files, and the panel
-- says so on each. Every step names a real permission, and every door a step
-- opens exists, both by foreign key or by assertion. The order the readers
-- found in the door bodies is the order here: people before companies, because
-- go-live needs two who can promote; features before packs before the finance
-- installer, because the installer reads a feature; sites before layout,
-- because a site seeds its own bays.
--
-- The screens read all of this through four doors. Two read, two write, and
-- the writers gate on the step's own permission: a step nobody could take is a
-- step nobody can tick.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The setup order
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_ref.setup_screen (
  screen_path text primary key references erp_ref.help_topic (screen_path),
  seq         smallint not null unique check (seq > 0),
  blurb       text not null check (length(btrim(blurb)) >= 20)
);

comment on table erp_ref.setup_screen is
  'The Settings screens in the order an organisation is set up. The Settings '
  'home lists its tiles in this order and says so; this is what says so.';

select erp_meta.register_table('erp_ref', 'setup_screen', 'product_content',
  'Part 22. The setup order the Settings walkthrough follows.');

insert into erp_ref.setup_screen (screen_path, seq, blurb) values
  ('/administration/onboarding', 1, 'Answer the interview. It proposes the configuration for everything below, as changes you approve.'),
  ('/administration/permissions', 2, 'The people, the roles they hold, and a second administrator: nothing goes live with one.'),
  ('/administration/organisation', 3, 'The companies, departments, approval bands, sites and locations everything else refers to.'),
  ('/administration/packs', 4, 'Features first, then the packs that bring the chart, tax and document types your legislation needs.'),
  ('/administration/configuration', 5, 'Install the modules you use, finance first; their configuration arrives as changes to approve and promote.'),
  ('/master-data', 6, 'Units of measure and business partners: the records the work is done with.'),
  ('/master-data/classification', 7, 'The categories products are described by, the templates that number them, and the products themselves.'),
  ('/master-data/item-supply', 8, 'Which supplier supplies which product, and on what terms.'),
  ('/inventory/warehouse', 9, 'Locations and bins within each site, and the rules for where stock goes.'),
  ('/logistics/release-areas', 10, 'Marshalling areas for picking and despatch.'),
  ('/finance/cost-centres', 11, 'Cost centres, before anything posts against them.'),
  ('/finance/dimensions', 12, 'Analysis dimensions beyond cost centre, and the accounts that require them.'),
  ('/finance/account-determination', 13, 'Accounting codes and the rules that decide which nominal account a posting lands on.'),
  ('/operations/output', 14, 'Printers, print routes, and the domain email is sent from.'),
  ('/operations/devices', 15, 'Scanners and the rules for what they accept.'),
  ('/operations/integrations', 16, 'API keys for service users and webhooks for the systems that listen.'),
  ('/operations/jobs', 17, 'Recurring tasks and their schedules.'),
  ('/operations/cutover', 18, 'Opening balances, parallel-run figures, and cutting each domain over.'),
  ('/administration/tenant', 19, 'Go live once the setup above is done. Keys and exports live here too.'),
  ('/operations/continuity', 20, 'Who is told when the platform has an incident.'),
  ('/administration/adoption', 21, 'Training scenarios for the people who will use it.'),
  ('/administration/terminology', 22, 'Your own words for the product''s, where they differ.'),
  ('/operations/assurance', 23, 'What the platform proves about this organisation, on demand.'),
  ('/administration/audit', 24, 'Who did what, and when, across the organisation.'),
  ('/administration/erasure', 25, 'Personal data requests, when one arrives.'),
  ('/administration/accessibility', 26, 'The accessibility statement.'),
  ('/administration/commercial', 27, 'The plan, its meters, and the agreement.')
on conflict (screen_path) do update set seq = excluded.seq, blurb = excluded.blurb;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The steps
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_ref.setup_step (
  code            text primary key check (code ~ '^[a-z_]+\.[a-z_]+$'),
  screen_path     text not null references erp_ref.setup_screen (screen_path),
  seq             smallint not null check (seq > 0),
  title           text not null check (length(btrim(title)) > 0),
  why             text not null check (length(btrim(why)) > 0),
  -- The action in the words of the screen it opens, so the panel renders a
  -- control rather than a hyperlink.
  action_label    text not null check (length(btrim(action_label)) > 0),
  -- The public door that control opens, when the step is a form on this
  -- screen. Null for a step that is reading, or that opens several forms.
  action_fn       text,
  permission_code text not null references erp_ref.permission (code),
  -- The platform can see for itself whether this was done; erp.setup_evidence()
  -- carries exactly one branch per step that says so.
  observable      boolean not null default false,
  -- Steps on this or other screens that must be complete first. Codes, so the
  -- panel can name them and link to them.
  requires        text[] not null default '{}',
  unique (screen_path, seq)
);

comment on table erp_ref.setup_step is
  'Part 22. One step of the Settings walkthrough: what to do, why, the door it '
  'opens, the permission it needs, and what has to exist first.';

select erp_meta.register_table('erp_ref', 'setup_step', 'product_content',
  'Part 22. The steps of the Settings walkthrough, per screen.');

insert into erp_ref.setup_step
  (code, screen_path, seq, title, why, action_label, action_fn, permission_code, observable, requires) values
  ('onboarding.start', '/administration/onboarding', 1, 'Start the interview', 'Each answer becomes configuration, proposed as a change; nothing is typed twice.', 'Start the interview', 'erp_start_interview', 'administration.configure', true, '{}'::text[]),
  ('onboarding.answer', '/administration/onboarding', 2, 'Answer the questions that apply', 'Skip what does not apply; a question left open is proposed as a default you can change later.', 'Answer a question', 'erp_answer_interview', 'administration.configure', true, array['onboarding.start']::text[]),
  ('onboarding.propose', '/administration/onboarding', 3, 'Propose the configuration', 'The answers become changes for a second administrator to approve and promote on Configuration.', 'Propose the configuration', 'erp_propose_from_interview', 'administration.configure', true, array['onboarding.answer']::text[]),
  ('permissions.invite', '/administration/permissions', 1, 'Invite the people', 'Each person is invited by email and claims their own account; nobody''s password is typed here.', 'Invite a person', 'erp_invite_principal', 'administration.users', true, '{}'::text[]),
  ('permissions.roles', '/administration/permissions', 2, 'Grant roles', 'A role carries permissions. Grant the fewest that let a person do their work, per company or site where it matters.', 'Grant a role', 'erp_grant_role', 'administration.roles', true, array['permissions.invite']::text[]),
  ('permissions.second_admin', '/administration/permissions', 3, 'Appoint a second administrator', 'Going live needs two people who can promote, and after it the author of a change may not approve it.', 'Grant a role', 'erp_grant_role', 'administration.roles', true, array['permissions.invite']::text[]),
  ('permissions.service', '/administration/permissions', 4, 'Create a service user for what connects', 'Scanners and integrations act as a service user with narrow roles, never as a person. Set it aside if nothing connects yet.', 'Create a service user', 'erp_create_service_principal', 'administration.users', true, '{}'::text[]),
  ('organisation.company', '/administration/organisation', 1, 'Add the companies you trade as', 'The organisation starts with one company. Add the others that keep their own accounts; a site, a ledger and a numbering rule each belong to one.', 'Create a company', 'erp_create_entity', 'administration.configure', true, '{}'::text[]),
  ('organisation.department', '/administration/organisation', 2, 'Add departments', 'Approval routing and cost defaults hang off departments; add the ones that approve spend first.', 'Add or amend a department', 'erp_upsert_department', 'administration.configure', true, array['organisation.company']::text[]),
  ('organisation.membership', '/administration/organisation', 3, 'Put people in departments', 'Routing finds an approver through membership; a person in no department is routed nowhere.', 'Assign someone to a department', 'erp_assign_department', 'administration.configure', true, array['organisation.department', 'permissions.invite']::text[]),
  ('organisation.band', '/administration/organisation', 4, 'Set approval bands', 'Value bands decide who approves what. Without one, every requisition and order waits on nobody.', 'Add or amend a band', 'erp_upsert_approval_band', 'administration.configure', true, array['organisation.department']::text[]),
  ('organisation.site', '/administration/organisation', 5, 'Add a site', 'Stock, receipts and despatches happen at a site, and a site belongs to a company. Adding one lays out its standard bays.', 'Add a site', 'erp_create_site', 'administration.configure', true, array['organisation.company']::text[]),
  ('organisation.location', '/administration/organisation', 6, 'Check the site''s locations', 'A site arrives with goods-in, bulk, pick and despatch bays. Add the ones your layout needs; Warehouse layout is where the detail lives.', 'Add a location', 'erp_create_location', 'administration.configure', true, array['organisation.site']::text[]),
  ('packs.features', '/administration/packs', 1, 'Switch on the features you use', 'A feature unlocks the packs and installers that need it; the finance installer reads the chart feature before it runs.', 'Switch a feature on', 'erp_set_capability', 'administration.configure', true, '{}'::text[]),
  ('packs.base', '/administration/packs', 2, 'Apply the base pack', 'The base pack brings the chart, tax and document types for your legislation; it arrives as a change to approve.', 'Apply a content pack', 'erp_apply_content_pack', 'administration.configure', true, array['packs.features']::text[]),
  ('packs.decide', '/administration/packs', 3, 'Answer the pack''s decisions', 'Some packs ask a question before they can apply, and record the answer rather than assume it.', 'Answer a decision', 'erp_answer_pack_decision', 'administration.configure', true, array['packs.base']::text[]),
  ('configuration.finance', '/administration/configuration', 1, 'Install finance first', 'The finance installer creates the ledgers and periods every other module posts into.', 'Configure finance', 'erp_configure_finance', 'administration.configure', true, array['packs.base']::text[]),
  ('configuration.modules', '/administration/configuration', 2, 'Install the other modules you use', 'Each installer proposes its configuration as a change; read each setting''s consequence before promoting it.', 'Open the installers', null, 'administration.configure', true, array['configuration.finance']::text[]),
  ('configuration.promote', '/administration/configuration', 3, 'Approve and promote the changes', 'Nothing takes effect until a second administrator approves and the change is promoted; Change requests is where that happens.', 'Submit a change for approval', 'erp_submit_change_set', 'administration.configure', true, array['permissions.second_admin']::text[]),
  ('configuration.reason_codes', '/administration/configuration', 4, 'Add reason codes', 'Adjustments, write-offs and overrides each need a reason from a list you control.', 'Add or amend a reason code', 'erp_upsert_reason_code', 'administration.configure', true, '{}'::text[]),
  ('master_data.uom', '/master-data', 1, 'Check the units of measure', 'Every product is stocked in a base unit. Add the ones the packs did not bring.', 'Create a unit of measure', 'erp_create_uom', 'master_data.write', true, '{}'::text[]),
  ('master_data.partner', '/master-data', 2, 'Create business partners', 'Suppliers and customers, each with the roles they play; every document names one.', 'Create a business partner with roles', 'erp_create_party_with_roles', 'master_data.write', true, '{}'::text[]),
  ('classification.axis', '/master-data/classification', 1, 'Declare the axes', 'An axis is a way products are described: brand, family, size. A mandatory axis must be answered before a product can be created.', 'Add or amend an axis', 'erp_upsert_classification_axis', 'master_data.write', true, '{}'::text[]),
  ('classification.value', '/master-data/classification', 2, 'Add their values', 'Values are what people pick from; an axis with none blocks the products that need it.', 'Add or amend a value', 'erp_upsert_classification_value', 'master_data.write', true, array['classification.axis']::text[]),
  ('classification.template', '/master-data/classification', 3, 'Set a code template', 'A template numbers new products from their classification, so a code means something.', 'Add or amend a code template', 'erp_upsert_code_template', 'master_data.write', true, array['classification.axis']::text[]),
  ('classification.product', '/master-data/classification', 4, 'Create products', 'A product is created classified, so its code and its behaviour come from the categories.', 'Create a classified product', 'erp_create_classified_item', 'master_data.write', true, array['classification.value', 'master_data.uom']::text[]),
  ('item_supply.supplier', '/master-data/item-supply', 1, 'Name a supplier for each product', 'Purchasing proposes the default supplier and its lead time; a product with none is ordered by hand.', 'Set or amend a supplier for a product', 'erp_set_item_supplier', 'master_data.write', true, array['classification.product', 'master_data.partner']::text[]),
  ('warehouse.layout', '/inventory/warehouse', 1, 'Lay out each site', 'Goods-in, bulk, pick and despatch locations, down to the bin where stock is tracked.', 'Add a location', 'erp_create_location', 'inventory.adjust', true, array['organisation.site']::text[]),
  ('warehouse.rules', '/inventory/warehouse', 2, 'Add storage rules', 'A rule puts a product where it belongs; without one, put-away asks every time.', 'Add a storage rule', 'erp_create_storage_rule', 'inventory.adjust', true, array['warehouse.layout']::text[]),
  ('release_areas.area', '/logistics/release-areas', 1, 'Add a marshalling area', 'Picked stock waits in a marshalling area until its wave is despatched.', 'Add or amend a marshalling area', 'erp_upsert_release_area', 'logistics.plan', true, array['warehouse.layout']::text[]),
  ('cost_centres.add', '/finance/cost-centres', 1, 'Add cost centres', 'Postings carry a cost centre from the department or the document; add them before anything posts.', 'Add or amend a cost centre', 'erp_upsert_cost_centre', 'finance.configure', true, array['organisation.company']::text[]),
  ('dimensions.declare', '/finance/dimensions', 1, 'Declare the dimensions you analyse by', 'Beyond cost centre: project, channel, region. Set it aside if cost centre is enough.', 'Add or amend a dimension', 'erp_upsert_dimension', 'finance.configure', true, '{}'::text[]),
  ('dimensions.values', '/finance/dimensions', 2, 'Add their values', 'A dimension with no values can be required but never filled.', 'Add or amend a value', 'erp_upsert_dimension_value', 'finance.configure', true, array['dimensions.declare']::text[]),
  ('dimensions.require', '/finance/dimensions', 3, 'Require dimensions on accounts', 'An account that requires a dimension refuses a posting without one.', 'Require dimensions on an account', 'erp_set_account_dimension_requirements', 'finance.configure', true, array['dimensions.declare']::text[]),
  ('account_determination.codes', '/finance/account-determination', 1, 'Add accounting codes', 'An accounting code groups products or partners for posting; the rules below read it.', 'Add or amend an accounting code', 'erp_upsert_posting_class', 'finance.configure', true, '{}'::text[]),
  ('account_determination.assign', '/finance/account-determination', 2, 'Give products and partners a code', 'A product or partner with no accounting code posts to nothing.', 'Set a product''s accounting code', 'erp_set_item_posting_class', 'finance.configure', true, array['account_determination.codes', 'classification.product']::text[]),
  ('account_determination.rules', '/finance/account-determination', 3, 'Write the determination rules', 'Each rule names the nominal account for a transaction type and an accounting code; the coverage report says what is still missing, and go-live needs it clear.', 'Add or amend a determination rule', 'erp_upsert_account_determination', 'finance.configure', true, array['account_determination.codes', 'configuration.finance']::text[]),
  ('output.printer', '/operations/output', 1, 'Register a printer', 'Labels and documents route to a printer at a site.', 'Register a printer', 'erp_upsert_printer', 'administration.configure', true, array['organisation.site']::text[]),
  ('output.route', '/operations/output', 2, 'Route output to it', 'A route says which printer takes which kind of output, for a site or a workstation.', 'Add a print route', 'erp_upsert_print_route', 'administration.configure', true, array['output.printer']::text[]),
  ('output.sender', '/operations/output', 3, 'Register a sending domain', 'Email leaves from your own domain once its DNS is verified; until then nothing is sent.', 'Register a sending domain', 'erp_upsert_sender_identity', 'administration.configure', true, '{}'::text[]),
  ('output.verify', '/operations/output', 4, 'Record the DNS verification', 'SPF, DKIM and DMARC, verified and recorded; the platform will not send from a domain it cannot prove.', 'Record DNS verification', 'erp_record_sender_verification', 'administration.configure', true, array['output.sender']::text[]),
  ('devices.register', '/operations/devices', 1, 'Register a scanner', 'A device is registered to a site and acts as its own service user.', 'Register a device', 'erp_register_device', 'administration.configure', true, array['organisation.site']::text[]),
  ('devices.rules', '/operations/devices', 2, 'Set scan rules', 'A rule says what a scan must carry for each task; without one, every scan is accepted.', 'Set a scan rule', 'erp_upsert_scan_rule', 'administration.configure', true, array['devices.register']::text[]),
  ('integrations.key', '/operations/integrations', 1, 'Issue an API key', 'A key belongs to a service user and can only narrow that user''s roles.', 'Issue an API key', 'erp_issue_api_key', 'administration.integrate', true, array['permissions.service']::text[]),
  ('integrations.webhook', '/operations/integrations', 2, 'Subscribe a webhook', 'Where an event is delivered, signed with a secret shown once.', 'Create a webhook subscription', 'erp_create_webhook_subscription', 'administration.integrate', true, '{}'::text[]),
  ('jobs.define', '/operations/jobs', 1, 'Define the recurring tasks', 'Reminders, sweeps and extracts run on a schedule you own; a kill switch stops one without deleting it.', 'Define a job', 'erp_upsert_job', 'administration.jobs', true, '{}'::text[]),
  ('cutover.opening', '/operations/cutover', 1, 'Stage opening balances', 'Stock, then ledgers, then nominal: staged, reconciled, and only then cut over. Nothing records the staging itself, so this one is yours to tick.', 'Stage opening balances', 'erp_stage_opening_balances', 'master_data.import', false, array['configuration.finance']::text[]),
  ('cutover.parallel', '/operations/cutover', 2, 'Record parallel-run figures', 'The old system''s figure beside this one, until they agree.', 'Record a parallel-run figure', 'erp_record_parallel_run_figure', 'master_data.import', true, array['cutover.opening']::text[]),
  ('cutover.cut', '/operations/cutover', 3, 'Cut each domain over', 'Cut over by someone other than the person who loaded it; a cutover can be reverted while the window is open.', 'Cut a domain over', 'erp_cut_over_domain', 'administration.configure', true, array['cutover.parallel']::text[]),
  ('tenant.go_live', '/administration/tenant', 1, 'Go live', 'Going live closes the setup window: from here configuration is proposed and promoted, never typed. It refuses while a determination finding is open or a second administrator is missing.', 'Run go-live checks', 'erp_go_live', 'administration.configure', true, array['permissions.second_admin', 'configuration.promote', 'account_determination.rules']::text[]),
  ('continuity.subscribe', '/operations/continuity', 1, 'Subscribe to incident notices', 'Somebody here should hear when the platform has an incident, before a customer does.', 'Set my incident subscription', 'erp_set_incident_subscription', 'administration.read', true, '{}'::text[]),
  ('adoption.scenario', '/administration/adoption', 1, 'Add a training scenario', 'A scenario is a task with a starting state and a completion check, for the people who will do the work.', 'Add a scenario', 'erp_upsert_training_scenario', 'administration.configure', true, '{}'::text[]),
  ('terminology.override', '/administration/terminology', 1, 'Put your own words in', 'Where your organisation says something differently, say it here; every screen string can be renamed.', 'Apply wording', 'erp_set_resource_override', 'administration.configure', true, '{}'::text[]),
  ('assurance.read', '/operations/assurance', 1, 'Read what the platform proves', 'Every registered check over this organisation, on demand. Nothing records that you looked, so this one is yours to tick.', 'Open assurance', null, 'administration.read', false, '{}'::text[]),
  ('audit.read', '/administration/audit', 1, 'Read the audit log', 'Who did what, when. Nothing records that you looked, so this one is yours to tick.', 'Open the audit log', null, 'administration.audit_read', false, '{}'::text[]),
  ('erasure.request', '/administration/erasure', 1, 'Know where erasure is requested', 'When a data subject asks, the request is raised here and executed with a certificate. Nothing to do until one arrives.', 'Request an erasure', 'erp_request_erasure', 'administration.users', true, '{}'::text[]),
  ('accessibility.read', '/administration/accessibility', 1, 'Read the accessibility statement', 'What the product commits to for people using assistive technology. Nothing records that you looked, so this one is yours to tick.', 'Open accessibility', null, 'administration.read', false, '{}'::text[]),
  ('commercial.read', '/administration/commercial', 1, 'Read the plan and its meters', 'What the agreement allows and what is being used. Nothing records that you looked, so this one is yours to tick.', 'Open plan and usage', null, 'administration.read', false, '{}'::text[])
on conflict (code) do update set
  screen_path = excluded.screen_path, seq = excluded.seq, title = excluded.title, why = excluded.why,
  action_label = excluded.action_label, action_fn = excluded.action_fn,
  permission_code = excluded.permission_code, observable = excluded.observable, requires = excluded.requires;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Progress, per organisation
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp.setup_progress (
  tenant_id    uuid not null references erp.tenant (id) on delete cascade,
  step_code    text not null references erp_ref.setup_step (code),
  done_at      timestamptz,
  dismissed_at timestamptz,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (tenant_id, step_code),
  -- "We did this" and "this is not for us" are different sentences, and a row
  -- that says neither is not a row.
  constraint setup_progress_says_something check (done_at is not null or dismissed_at is not null)
);

comment on table erp.setup_progress is
  'Part 22. Which setup steps an organisation has ticked or set aside. The '
  'evidence function decides where it can; this is where a person decides.';

select erp_meta.register_table('erp', 'setup_progress', 'tenant_scoped',
  'Part 22. Setup walkthrough ticks and dismissals, per organisation.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The evidence: one branch per observable step, read from the organisation
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.setup_evidence()
returns table (step_code text, satisfied boolean, evidence text)
language sql
stable
security invoker
set search_path = ''
as $$
  with t as (select erp.current_tenant_id() as id)
  select 'onboarding.start'::text, (n >= 1), (case when n = 0 then 'the interview has not been started' when n = 1 then 'the interview has been started' else n || ' interview sessions exist' end)
    from (select (select count(*) from erp.interview_session i, t where i.tenant_id = t.id) as n) x
  union all
  select 'onboarding.answer'::text, (n >= 1), (case when n = 0 then 'no question has been answered yet' when n = 1 then 'one question has been answered' else n || ' questions have been answered' end)
    from (select (select count(*) from erp.interview_answer a, t where a.tenant_id = t.id) as n) x
  union all
  select 'onboarding.propose'::text, (n >= 1), (case when n = 0 then 'nothing has been proposed from the interview yet' when n = 1 then 'the interview has proposed its configuration' else n || ' proposals have been made from the interview' end)
    from (select (select count(*) from erp.interview_session i, t where i.tenant_id = t.id and i.proposed_at is not null) as n) x
  union all
  select 'permissions.invite'::text, (n >= 2), (case when n = 0 then 'nobody has an account yet' when n = 1 then 'only you have an account' else n || ' people have accounts' end)
    from (select (select count(*) from erp.app_user u, t where u.tenant_id = t.id and u.kind = 'person') as n) x
  union all
  select 'permissions.roles'::text, (n >= 2), (case when n = 0 then 'nobody holds a role yet' when n = 1 then 'only one person holds a role' else n || ' people hold a role' end)
    from (select (select count(distinct ur.app_user_id) from erp.user_role ur, t where ur.tenant_id = t.id and (ur.valid_to is null or ur.valid_to >= current_date)) as n) x
  union all
  select 'permissions.second_admin'::text, (n >= 2), (case when n = 0 then 'nobody can promote a change yet' when n = 1 then 'only one person can promote a change' else n || ' people can promote a change' end)
    from (select (select count(distinct ur.app_user_id) from erp.user_role ur join erp.role_permission rp on rp.tenant_id = ur.tenant_id and rp.role_id = ur.role_id, t where ur.tenant_id = t.id and rp.permission_code = 'administration.promote' and (ur.valid_to is null or ur.valid_to >= current_date)) as n) x
  union all
  select 'permissions.service'::text, (n >= 1), (case when n = 0 then 'no service user yet' when n = 1 then 'one service user' else n || ' service users' end)
    from (select (select count(*) from erp.app_user u, t where u.tenant_id = t.id and u.kind = 'service') as n) x
  union all
  select 'organisation.company'::text, (n >= 1), (case when n = 0 then 'no company yet' when n = 1 then 'one company' else n || ' companies' end)
    from (select (select count(*) from erp.entity e, t where e.tenant_id = t.id and e.status = 'active') as n) x
  union all
  select 'organisation.department'::text, (n >= 1), (case when n = 0 then 'no department yet' when n = 1 then 'one department' else n || ' departments' end)
    from (select (select count(*) from erp.department d, t where d.tenant_id = t.id and d.status = 'active') as n) x
  union all
  select 'organisation.membership'::text, (n >= 1), (case when n = 0 then 'nobody is in a department yet' when n = 1 then 'one person is in a department' else n || ' memberships' end)
    from (select (select count(*) from erp.principal_department m, t where m.tenant_id = t.id and m.status = 'active') as n) x
  union all
  select 'organisation.band'::text, (n >= 1), (case when n = 0 then 'no approval band yet' when n = 1 then 'one approval band' else n || ' approval bands' end)
    from (select (select count(*) from erp.approval_band b, t where b.tenant_id = t.id and b.status = 'active') as n) x
  union all
  select 'organisation.site'::text, (n >= 1), (case when n = 0 then 'no site yet' when n = 1 then 'one site' else n || ' sites' end)
    from (select (select count(*) from erp.site s, t where s.tenant_id = t.id and s.status = 'active') as n) x
  union all
  select 'organisation.location'::text, (n >= 1), (case when n = 0 then 'no location yet' when n = 1 then 'one location' else n || ' locations' end)
    from (select (select count(*) from erp.location l, t where l.tenant_id = t.id) as n) x
  union all
  select 'packs.features'::text, (n >= 1), (case when n = 0 then 'no feature is switched on yet' when n = 1 then 'one feature is on' else n || ' features are on' end)
    from (select (select count(*) from erp.tenant_capability c, t where c.tenant_id = t.id and c.is_enabled) as n) x
  union all
  select 'packs.base'::text, (n >= 1), (case when n = 0 then 'no pack has been applied yet' when n = 1 then 'one pack has been applied' else n || ' packs have been applied' end)
    from (select (select count(*) from erp.tenant_pack p, t where p.tenant_id = t.id and p.status = 'applied') as n) x
  union all
  select 'packs.decide'::text, (n >= 1), (case when n = 0 then 'no pack decision has been answered' when n = 1 then 'one pack decision has been answered' else n || ' pack decisions have been answered' end)
    from (select (select count(*) from erp.pack_decision d, t where d.tenant_id = t.id) as n) x
  union all
  select 'configuration.finance'::text, (n >= 1), (case when n = 0 then 'finance is not installed yet' when n = 1 then 'finance is installed' else n || ' finance installations' end)
    from (select (select count(*) from erp.module_installation m, t where m.tenant_id = t.id and m.module_code = 'finance') as n) x
  union all
  select 'configuration.modules'::text, (n >= 2), (case when n = 0 then 'no module is installed yet' when n = 1 then 'only one module is installed' else n || ' modules are installed' end)
    from (select (select count(*) from erp.module_installation m, t where m.tenant_id = t.id) as n) x
  union all
  select 'configuration.promote'::text, (n >= 1), (case when n = 0 then 'nothing has been promoted yet' when n = 1 then 'one change has been promoted' else n || ' changes have been promoted' end)
    from (select (select count(*) from erp.change_set c, t where c.tenant_id = t.id and c.status = 'promoted') as n) x
  union all
  select 'configuration.reason_codes'::text, (n >= 1), (case when n = 0 then 'no reason code yet' when n = 1 then 'one reason code' else n || ' reason codes' end)
    from (select (select count(*) from erp.reason_code r, t where r.tenant_id = t.id and r.status = 'active') as n) x
  union all
  select 'master_data.uom'::text, (n >= 1), (case when n = 0 then 'no unit of measure yet' when n = 1 then 'one unit of measure' else n || ' units of measure' end)
    from (select (select count(*) from erp.uom u, t where u.tenant_id = t.id and u.status = 'active') as n) x
  union all
  select 'master_data.partner'::text, (n >= 1), (case when n = 0 then 'no business partner yet' when n = 1 then 'one business partner' else n || ' business partners' end)
    from (select (select count(*) from erp.party p, t where p.tenant_id = t.id and p.status = 'active') as n) x
  union all
  select 'classification.axis'::text, (n >= 1), (case when n = 0 then 'no axis yet' when n = 1 then 'one axis' else n || ' axes' end)
    from (select (select count(*) from erp.classification_axis a, t where a.tenant_id = t.id and a.status = 'active') as n) x
  union all
  select 'classification.value'::text, (n >= 1), (case when n = 0 then 'no value yet' when n = 1 then 'one value' else n || ' values' end)
    from (select (select count(*) from erp.classification_value v, t where v.tenant_id = t.id and v.status = 'active') as n) x
  union all
  select 'classification.template'::text, (n >= 1), (case when n = 0 then 'no code template yet' when n = 1 then 'one code template' else n || ' code templates' end)
    from (select (select count(*) from erp.code_template c, t where c.tenant_id = t.id and c.status = 'active') as n) x
  union all
  select 'classification.product'::text, (n >= 1), (case when n = 0 then 'no product yet' when n = 1 then 'one product' else n || ' products' end)
    from (select (select count(*) from erp.item i, t where i.tenant_id = t.id) as n) x
  union all
  select 'item_supply.supplier'::text, (n >= 1), (case when n = 0 then 'no product has a supplier yet' when n = 1 then 'one product has a supplier' else n || ' product-supplier relationships' end)
    from (select (select count(*) from erp.item_supplier s, t where s.tenant_id = t.id) as n) x
  union all
  select 'warehouse.layout'::text, (n = 3), (case when n = 0 then 'no goods-in, bulk or pick location yet' when n = 3 then 'goods-in, bulk and pick locations exist' else n || ' of the three location kinds exist' end)
    from (select (select count(distinct l.location_type::text) from erp.location l, t where l.tenant_id = t.id and l.location_type::text in ('receiving', 'bulk', 'pick')) as n) x
  union all
  select 'warehouse.rules'::text, (n >= 1), (case when n = 0 then 'no storage rule yet' when n = 1 then 'one storage rule' else n || ' storage rules' end)
    from (select (select count(*) from erp.storage_rule r, t where r.tenant_id = t.id and r.status = 'active') as n) x
  union all
  select 'release_areas.area'::text, (n >= 1), (case when n = 0 then 'no marshalling area yet' when n = 1 then 'one marshalling area' else n || ' marshalling areas' end)
    from (select (select count(*) from erp.release_area a, t where a.tenant_id = t.id and a.status = 'active') as n) x
  union all
  select 'cost_centres.add'::text, (n >= 1), (case when n = 0 then 'no cost centre yet' when n = 1 then 'one cost centre' else n || ' cost centres' end)
    from (select (select count(*) from erp.dimension_value v join erp.dimension d on d.tenant_id = v.tenant_id and d.id = v.dimension_id, t where v.tenant_id = t.id and d.code = 'cost_centre' and v.status = 'active') as n) x
  union all
  select 'dimensions.declare'::text, (n >= 1), (case when n = 0 then 'no dimension beyond cost centre yet' when n = 1 then 'one dimension beyond cost centre' else n || ' dimensions beyond cost centre' end)
    from (select (select count(*) from erp.dimension d, t where d.tenant_id = t.id and d.status = 'active' and d.code <> 'cost_centre') as n) x
  union all
  select 'dimensions.values'::text, (n >= 1), (case when n = 0 then 'no dimension value yet' when n = 1 then 'one dimension value' else n || ' dimension values' end)
    from (select (select count(*) from erp.dimension_value v join erp.dimension d on d.tenant_id = v.tenant_id and d.id = v.dimension_id, t where v.tenant_id = t.id and d.code <> 'cost_centre' and v.status = 'active') as n) x
  union all
  select 'dimensions.require'::text, (n >= 1), (case when n = 0 then 'no account requires a dimension yet' when n = 1 then 'one account requires a dimension' else n || ' accounts require a dimension' end)
    from (select (select count(*) from erp.account a, t where a.tenant_id = t.id and coalesce(cardinality(a.requires_dimensions), 0) > 0) as n) x
  union all
  select 'account_determination.codes'::text, (n >= 1), (case when n = 0 then 'no accounting code yet' when n = 1 then 'one accounting code' else n || ' accounting codes' end)
    from (select (select count(*) from erp.posting_class p, t where p.tenant_id = t.id and p.status = 'active') as n) x
  union all
  select 'account_determination.assign'::text, (n >= 1), (case when n = 0 then 'no product or partner has an accounting code yet' when n = 1 then 'one product or partner has an accounting code' else n || ' products and partners have an accounting code' end)
    from (select (select (select count(*) from erp.item_posting_class x, t where x.tenant_id = t.id) + (select count(*) from erp.party_posting_class y, t where y.tenant_id = t.id)) as n) x
  union all
  select 'account_determination.rules'::text, (n >= 1), (case when n = 0 then 'no determination rule yet' when n = 1 then 'one determination rule' else n || ' determination rules' end)
    from (select (select count(*) from erp.account_determination r, t where r.tenant_id = t.id) as n) x
  union all
  select 'output.printer'::text, (n >= 1), (case when n = 0 then 'no printer yet' when n = 1 then 'one printer' else n || ' printers' end)
    from (select (select count(*) from erp.printer p, t where p.tenant_id = t.id and p.status = 'active') as n) x
  union all
  select 'output.route'::text, (n >= 1), (case when n = 0 then 'no print route yet' when n = 1 then 'one print route' else n || ' print routes' end)
    from (select (select count(*) from erp.print_route r, t where r.tenant_id = t.id and r.status = 'active') as n) x
  union all
  select 'output.sender'::text, (n >= 1), (case when n = 0 then 'no sending domain yet' when n = 1 then 'one sending domain' else n || ' sending domains' end)
    from (select (select count(*) from erp.sender_identity s, t where s.tenant_id = t.id) as n) x
  union all
  select 'output.verify'::text, (n >= 1), (case when n = 0 then 'no sending domain is verified yet' when n = 1 then 'one sending domain is verified' else n || ' sending domains are verified' end)
    from (select (select count(*) from erp.sender_identity s, t where s.tenant_id = t.id and s.verified_at is not null) as n) x
  union all
  select 'devices.register'::text, (n >= 1), (case when n = 0 then 'no device yet' when n = 1 then 'one device' else n || ' devices' end)
    from (select (select count(*) from erp.device d, t where d.tenant_id = t.id and d.status = 'active') as n) x
  union all
  select 'devices.rules'::text, (n >= 1), (case when n = 0 then 'no scan rule yet' when n = 1 then 'one scan rule' else n || ' scan rules' end)
    from (select (select count(*) from erp.scan_rule r, t where r.tenant_id = t.id) as n) x
  union all
  select 'integrations.key'::text, (n >= 1), (case when n = 0 then 'no API key yet' when n = 1 then 'one API key' else n || ' API keys' end)
    from (select (select count(*) from erp.api_key k, t where k.tenant_id = t.id and k.revoked_at is null) as n) x
  union all
  select 'integrations.webhook'::text, (n >= 1), (case when n = 0 then 'no webhook yet' when n = 1 then 'one webhook' else n || ' webhooks' end)
    from (select (select count(*) from erp.webhook_subscription w, t where w.tenant_id = t.id) as n) x
  union all
  select 'jobs.define'::text, (n >= 1), (case when n = 0 then 'no recurring task yet' when n = 1 then 'one recurring task' else n || ' recurring tasks' end)
    from (select (select count(*) from erp.job j, t where j.tenant_id = t.id) as n) x
  union all
  select 'cutover.parallel'::text, (n >= 1), (case when n = 0 then 'no parallel-run figure yet' when n = 1 then 'one parallel-run figure' else n || ' parallel-run figures' end)
    from (select (select count(*) from erp.parallel_run_figure f, t where f.tenant_id = t.id) as n) x
  union all
  select 'cutover.cut'::text, (n >= 1), (case when n = 0 then 'no domain has been cut over yet' when n = 1 then 'one domain has been cut over' else n || ' domains have been cut over' end)
    from (select (select count(*) from erp.domain_cutover c, t where c.tenant_id = t.id and c.status = 'cut_over') as n) x
  union all
  select 'tenant.go_live'::text, (n >= 1), (case when n = 0 then 'not live yet: still in the setup window' else 'live' end)
    from (select (select count(*) from erp.environment e, t where e.tenant_id = t.id and e.is_self and e.is_live) as n) x
  union all
  select 'continuity.subscribe'::text, (n >= 1), (case when n = 0 then 'nobody is subscribed to incident notices' when n = 1 then 'one person is subscribed to incident notices' else n || ' people are subscribed to incident notices' end)
    from (select (select count(*) from erp.incident_subscription s, t where s.tenant_id = t.id and s.is_subscribed) as n) x
  union all
  select 'adoption.scenario'::text, (n >= 1), (case when n = 0 then 'no training scenario yet' when n = 1 then 'one training scenario' else n || ' training scenarios' end)
    from (select (select count(*) from erp.training_scenario s, t where s.tenant_id = t.id and s.status = 'active') as n) x
  union all
  select 'terminology.override'::text, (n >= 1), (case when n = 0 then 'no wording has been changed' when n = 1 then 'one word has been changed' else n || ' words have been changed' end)
    from (select (select count(*) from erp.resource_override o, t where o.tenant_id = t.id and o.status = 'active') as n) x
  union all
  select 'erasure.request'::text, (n >= 1), (case when n = 0 then 'no erasure has been requested' when n = 1 then 'one erasure has been requested' else n || ' erasures have been requested' end)
    from (select (select count(*) from erp.erasure_request r, t where r.tenant_id = t.id) as n) x
$$;

comment on function erp.setup_evidence is
  'Part 22. For every observable setup step, whether the organisation''s own '
  'tables say it was done, and a sentence saying what was looked at. With no '
  'organisation in context every branch reads nothing and says so.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The reads
-- ═════════════════════════════════════════════════════════════════════════════

-- Every step of one screen, with the evidence, the organisation's own ticks,
-- whether the caller may take it, and the steps it still waits on.
create or replace function erp.setup_walkthrough(p_screen_path text)
returns table (screen_path text, screen_seq smallint, code text, seq smallint, title text, why text,
               action_label text, action_fn text, permission_code text, permitted boolean,
               observable boolean, satisfied boolean, evidence text,
               done_at timestamptz, dismissed_at timestamptz, complete boolean, blocked boolean,
               requires jsonb)
language sql
stable
security invoker
set search_path = ''
as $$
  with state as (
    select s.code, s.title, s.screen_path,
           (coalesce(e.satisfied, false) or p.done_at is not null or p.dismissed_at is not null) as complete
      from erp_ref.setup_step s
      left join erp.setup_evidence() e on e.step_code = s.code
      left join erp.setup_progress p on p.tenant_id = erp.current_tenant_id() and p.step_code = s.code
  )
  select s.screen_path, sc.seq, s.code, s.seq, s.title, s.why,
         s.action_label, s.action_fn, s.permission_code,
         erp.has_permission(s.permission_code, null, null, null, erp.current_principal_id()) as permitted,
         s.observable, coalesce(e.satisfied, false) as satisfied, e.evidence,
         p.done_at, p.dismissed_at,
         st.complete,
         exists (select 1 from unnest(s.requires) r join state x on x.code = r where not x.complete) as blocked,
         coalesce((select jsonb_agg(jsonb_build_object('code', x.code, 'title', x.title,
                                                       'screen_path', x.screen_path, 'complete', x.complete)
                                    order by x.code)
                     from unnest(s.requires) r join state x on x.code = r), '[]'::jsonb) as requires
    from erp_ref.setup_step s
    join erp_ref.setup_screen sc on sc.screen_path = s.screen_path
    join state st on st.code = s.code
    left join erp.setup_evidence() e on e.step_code = s.code
    left join erp.setup_progress p on p.tenant_id = erp.current_tenant_id() and p.step_code = s.code
   where s.screen_path = p_screen_path
   order by s.seq
$$;

-- Every screen in the order, with how far along it is and the next step on it.
create or replace function erp.setup_progress_by_screen()
returns table (screen_path text, seq smallint, title text, blurb text, total integer, complete integer,
               next_code text, next_title text, next_action_label text)
language sql
stable
security invoker
set search_path = ''
as $$
  with state as (
    select s.code, s.seq, s.title, s.action_label, s.screen_path,
           (coalesce(e.satisfied, false) or p.done_at is not null or p.dismissed_at is not null) as complete
      from erp_ref.setup_step s
      left join erp.setup_evidence() e on e.step_code = s.code
      left join erp.setup_progress p on p.tenant_id = erp.current_tenant_id() and p.step_code = s.code
  )
  select sc.screen_path, sc.seq, erp.text(h.nav_key) as title, sc.blurb,
         (select count(*) from state x where x.screen_path = sc.screen_path)::integer as total,
         (select count(*) from state x where x.screen_path = sc.screen_path and x.complete)::integer as complete,
         n.code, n.title, n.action_label
    from erp_ref.setup_screen sc
    join erp_ref.help_topic h on h.screen_path = sc.screen_path
    left join lateral (select x.code, x.title, x.action_label from state x
                        where x.screen_path = sc.screen_path and not x.complete
                        order by x.seq limit 1) n on true
   order by sc.seq
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The writers: a tick and a "not for us", both for the organisation
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.mark_setup_step(p_code text, p_done boolean default true)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_perm   text;
begin
  select s.permission_code into v_perm from erp_ref.setup_step s where s.code = p_code;
  if v_perm is null then
    raise exception 'CLOVEERP_UNKNOWN_SETUP_STEP: % is not a setup step', p_code
      using errcode = '23503',
            hint = 'Take the step from the walkthrough, which offers only steps that exist.';
  end if;
  -- The step is the caller's to mark only if it was theirs to take.
  perform erp.authorise(v_perm, null, null, null, 'setup_step', null);

  if p_done then
    insert into erp.setup_progress (tenant_id, step_code, done_at)
    values (v_tenant, p_code, now())
    on conflict (tenant_id, step_code) do update set done_at = now();
  else
    -- A row that would then say nothing goes; one that still says "not for
    -- us" stays and loses its tick.
    delete from erp.setup_progress
     where tenant_id = v_tenant and step_code = p_code and dismissed_at is null;
    update erp.setup_progress set done_at = null
     where tenant_id = v_tenant and step_code = p_code;
  end if;
end;
$$;

create or replace function erp.dismiss_setup_step(p_code text, p_dismissed boolean default true)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_perm   text;
begin
  select s.permission_code into v_perm from erp_ref.setup_step s where s.code = p_code;
  if v_perm is null then
    raise exception 'CLOVEERP_UNKNOWN_SETUP_STEP: % is not a setup step', p_code
      using errcode = '23503',
            hint = 'Take the step from the walkthrough, which offers only steps that exist.';
  end if;
  perform erp.authorise(v_perm, null, null, null, 'setup_step', null);

  if p_dismissed then
    insert into erp.setup_progress (tenant_id, step_code, dismissed_at)
    values (v_tenant, p_code, now())
    on conflict (tenant_id, step_code) do update set dismissed_at = now();
  else
    delete from erp.setup_progress
     where tenant_id = v_tenant and step_code = p_code and done_at is null;
    update erp.setup_progress set dismissed_at = null
     where tenant_id = v_tenant and step_code = p_code;
  end if;
end;
$$;

comment on function erp.dismiss_setup_step is
  'Part 22. Sets a setup step aside as not applying to this organisation, or '
  'brings it back. Recorded separately from done, because "we did this" and '
  '"this is not for us" are different sentences.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The doors
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_setup_walkthrough(p_screen_path text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform erp.require_tenant_id();
  return jsonb_build_object(
    'screen', (
      select jsonb_build_object(
        'screen_path', sc.screen_path, 'seq', sc.seq, 'title', erp.text(h.nav_key), 'blurb', sc.blurb,
        'previous', (select jsonb_build_object('screen_path', p.screen_path, 'title', erp.text(ph.nav_key))
                       from erp_ref.setup_screen p join erp_ref.help_topic ph on ph.screen_path = p.screen_path
                      where p.seq = sc.seq - 1),
        'next', (select jsonb_build_object('screen_path', n.screen_path, 'title', erp.text(nh.nav_key))
                   from erp_ref.setup_screen n join erp_ref.help_topic nh on nh.screen_path = n.screen_path
                  where n.seq = sc.seq + 1),
        'screens', (select count(*) from erp_ref.setup_screen))
        from erp_ref.setup_screen sc
        join erp_ref.help_topic h on h.screen_path = sc.screen_path
       where sc.screen_path = p_screen_path),
    'steps', coalesce((
      select jsonb_agg(jsonb_build_object(
        'code', w.code, 'seq', w.seq, 'title', w.title, 'why', w.why,
        'action_label', w.action_label, 'action_fn', w.action_fn,
        'permission_code', w.permission_code, 'permitted', w.permitted,
        'observable', w.observable, 'satisfied', w.satisfied, 'evidence', w.evidence,
        'done_at', w.done_at, 'dismissed_at', w.dismissed_at,
        'complete', w.complete, 'blocked', w.blocked, 'requires', w.requires)
        order by w.seq)
        from erp.setup_walkthrough(p_screen_path) w), '[]'::jsonb));
end;
$$;

comment on function public.erp_setup_walkthrough is
  'Part 22. The walkthrough for one Settings screen: its place in the setup '
  'order, and every step with the evidence, the organisation''s ticks, whether '
  'the caller may take it, and what it still waits on.';

create or replace function public.erp_setup_progress()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform erp.require_tenant_id();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'screen_path', p.screen_path, 'seq', p.seq, 'title', p.title, 'blurb', p.blurb,
      'total', p.total, 'complete', p.complete,
      'next', case when p.next_code is null then null
                   else jsonb_build_object('code', p.next_code, 'title', p.next_title, 'action_label', p.next_action_label) end)
      order by p.seq)
    from erp.setup_progress_by_screen() p), '[]'::jsonb);
end;
$$;

comment on function public.erp_setup_progress is
  'Part 22. Every Settings screen in setup order with how far along it is and '
  'the next step on it, for the Settings home.';

create or replace function public.erp_mark_setup_step(p_code text, p_done boolean default true)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
begin
  perform erp.mark_setup_step(p_code, p_done);
  return jsonb_build_object('code', p_code, 'done', p_done);
end;
$$;

create or replace function public.erp_dismiss_setup_step(p_code text, p_dismissed boolean default true)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
begin
  perform erp.dismiss_setup_step(p_code, p_dismissed);
  return jsonb_build_object('code', p_code, 'dismissed', p_dismissed);
end;
$$;

revoke all on function public.erp_setup_walkthrough(text) from public, anon;
revoke all on function public.erp_setup_progress() from public, anon;
revoke all on function public.erp_mark_setup_step(text, boolean) from public, anon;
revoke all on function public.erp_dismiss_setup_step(text, boolean) from public, anon;
grant execute on function public.erp_setup_walkthrough(text) to authenticated, service_role;
grant execute on function public.erp_setup_progress() to authenticated, service_role;
grant execute on function public.erp_mark_setup_step(text, boolean) to authenticated, service_role;
grant execute on function public.erp_dismiss_setup_step(text, boolean) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_mark_setup_step', 'erp.mark_setup_step',
   'Part 22. Ticks one of the organisation''s setup steps, or removes the tick. Gates on the step''s own permission: a step nobody could take is a step nobody can tick.'),
  ('erp_dismiss_setup_step', 'erp.dismiss_setup_step',
   'Part 22. Sets one of the organisation''s setup steps aside as not applying, or brings it back. Gates on the step''s own permission.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The register is held to what it claims
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.setup_walkthrough_report()
returns table (finding text, step_code text, detail text)
language sql
stable
set search_path = ''
as $$
  -- A step that claims to be observable and nothing looks.
  select 'an observable step has no evidence branch', s.code, s.title
    from erp_ref.setup_step s
   where s.observable
     and not exists (select 1 from erp.setup_evidence() e where e.step_code = s.code)
  union all
  -- A branch that looks at a step the register does not mark observable, or
  -- that does not exist.
  select 'the evidence function reads a step that is not observable', e.step_code, ''
    from erp.setup_evidence() e
   where not exists (select 1 from erp_ref.setup_step s where s.code = e.step_code and s.observable)
  union all
  select 'the evidence function reads a step twice', e.step_code, count(*)::text || ' branches'
    from erp.setup_evidence() e
   group by e.step_code having count(*) > 1
  union all
  -- The door a step opens must exist.
  select 'a step opens a door that does not exist', s.code, s.action_fn
    from erp_ref.setup_step s
   where s.action_fn is not null
     and not exists (select 1 from pg_catalog.pg_proc p
                      where p.pronamespace = 'public'::regnamespace and p.proname = s.action_fn)
  union all
  -- What a step requires must exist, and must come first in the order.
  select 'a step requires a step that does not exist', s.code, r
    from erp_ref.setup_step s, unnest(s.requires) r
   where not exists (select 1 from erp_ref.setup_step x where x.code = r)
  union all
  select 'a step requires a step that comes after it', s.code, r
    from erp_ref.setup_step s
    join erp_ref.setup_screen sc on sc.screen_path = s.screen_path,
    unnest(s.requires) r
    join erp_ref.setup_step x on x.code = r
    join erp_ref.setup_screen xc on xc.screen_path = x.screen_path
   where (xc.seq, x.seq) >= (sc.seq, s.seq)
  union all
  -- Every screen in the order has a first step, and the order has no gaps.
  select 'a screen in the setup order has no first step', sc.screen_path, ''
    from erp_ref.setup_screen sc
   where not exists (select 1 from erp_ref.setup_step s where s.screen_path = sc.screen_path and s.seq = 1)
  union all
  select 'the setup order has a gap', sc.seq::text, ''
    from erp_ref.setup_screen sc
   where sc.seq > 1 and not exists (select 1 from erp_ref.setup_screen p where p.seq = sc.seq - 1)
$$;

comment on function erp.setup_walkthrough_report is
  'Part 22. What is wrong with the setup walkthrough register, if anything: an '
  'observable step nothing looks at, a branch for a step that is not '
  'observable, a door that does not exist, a requirement that does not exist '
  'or comes later, a screen with no first step, a gap in the order.';

create or replace function erp.assert_setup_walkthrough_actionable()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_count    integer;
  v_findings text;
  v_steps    integer;
  v_screens  integer;
  v_observed integer;
begin
  select count(*), string_agg(format('  %s [%s] %s', r.finding, r.step_code, r.detail), E'\n' order by r.finding, r.step_code)
    into v_count, v_findings
    from erp.setup_walkthrough_report() r;
  if v_count > 0 then
    raise exception E'CLOVEERP_SETUP_WALKTHROUGH_BROKEN: % finding(s)\n%', v_count, v_findings
      using errcode = 'P0001',
            hint = 'Add the branch to erp.setup_evidence(), clear observable on the step, fix the door or the requirement, or give the screen its first step.';
  end if;
  select count(*), count(*) filter (where s.observable), count(distinct s.screen_path)
    into v_steps, v_observed, v_screens
    from erp_ref.setup_step s;
  return format('setup walkthrough: %s steps across %s screens, %s observed from the organisation''s own state, every one naming an action',
                v_steps, v_screens, v_observed);
end;
$$;

comment on function erp.assert_setup_walkthrough_actionable is
  'Part 22. Fails when the setup walkthrough register and the evidence function '
  'disagree, when a step opens a door that does not exist, when a requirement '
  'does not exist or comes later in the order, or when a screen has no first step.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('setup_walkthrough', 'The Settings walkthrough is actionable', 'assertion', 'platform',
   'erp', 'assert_setup_walkthrough_actionable', '', 'setup_walkthrough_report', '',
   'Every setup step names the action it opens and a door that exists, every observable step has a branch of erp.setup_evidence() that looks, every requirement exists and comes first, and every screen in the order has a first step. The message reports how many steps complete themselves.',
   true, (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name, arguments = excluded.arguments,
  detail_function = excluded.detail_function, detail_arguments = excluded.detail_arguments,
  blurb = excluded.blurb, runs_in_ci = excluded.runs_in_ci;

-- ── The refusal a door raises ────────────────────────────────────────────────
--
-- Only the writers' refusal is registered. The assertion and the suite raise
-- their own codes with a hint, as every assertion and suite wrapper here does,
-- and erp.refusal_report() does not read them: registering a code it cannot
-- see raised is a finding of its own.
select erp.register_refusal('CLOVEERP_UNKNOWN_SETUP_STEP',
  'Ticking or setting aside a setup step that does not exist.',
  'The walkthrough offers only steps that are registered; an unknown one came from somewhere else.',
  'Reload the screen and take the step from its walkthrough.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.setup_walkthrough_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_steps    integer;
  v_observed integer;
  v_branches integer;
  v_screens  integer;
  v_msg      text;
begin
  select count(*), count(*) filter (where observable) into v_steps, v_observed from erp_ref.setup_step;
  select count(*) into v_branches from erp.setup_evidence();
  select count(*) into v_screens from erp_ref.setup_screen;

  return query select 'every screen in the setup order has a first step',
    not exists (select 1 from erp_ref.setup_screen sc
                 where not exists (select 1 from erp_ref.setup_step s where s.screen_path = sc.screen_path and s.seq = 1)),
    format('%s screens', v_screens);
  return query select 'the setup order runs from one to the last screen without a gap',
    (select count(*) from erp_ref.setup_screen) = (select max(seq) from erp_ref.setup_screen),
    format('%s screens, highest seq %s', v_screens, (select max(seq) from erp_ref.setup_screen));
  return query select 'every step names the action it opens',
    not exists (select 1 from erp_ref.setup_step where length(btrim(action_label)) = 0),
    format('%s steps', v_steps);
  return query select 'the evidence function has exactly one branch per observable step',
    v_branches = v_observed, format('%s branches for %s observable steps', v_branches, v_observed);
  return query select 'most of the register completes itself rather than asking',
    v_observed >= v_steps - 8 and v_observed < v_steps,
    format('%s of %s steps are observed', v_observed, v_steps);
  v_msg := erp.assert_setup_walkthrough_actionable();
  return query select 'the assertion reports the register rather than claiming it is complete',
    v_msg ~ '^setup walkthrough: \d+ steps across \d+ screens, \d+ observed', v_msg;
  return query select 'with no organisation in context the evidence is empty, not an error',
    not exists (select 1 from erp.setup_evidence() where satisfied),
    format('%s branches, none satisfied', v_branches);
  return query select 'and each branch still says what it looked for',
    not exists (select 1 from erp.setup_evidence() where evidence is null or length(btrim(evidence)) = 0),
    'every branch returns a sentence';
  return query select 'the report finds nothing to say about a sound register',
    (select count(*) from erp.setup_walkthrough_report()) = 0,
    format('%s finding(s)', (select count(*) from erp.setup_walkthrough_report()));
  return query select 'on the organisation screen the company comes before the site that needs it',
    (select s.seq from erp_ref.setup_step s where s.code = 'organisation.company')
      < (select s.seq from erp_ref.setup_step s where s.code = 'organisation.site')
    and 'organisation.company' = any ((select s.requires from erp_ref.setup_step s where s.code = 'organisation.site')),
    'organisation.company before organisation.site, and required by it';
  return query select 'a progress row must say something: done, dismissed, or it does not exist',
    exists (select 1 from pg_constraint
             where conrelid = 'erp.setup_progress'::regclass and conname = 'setup_progress_says_something'),
    'setup_progress_says_something';
  return query select 'both writers are registered against the gates they reach',
    (select count(*) from erp_meta.public_write_allowance
      where (function_name, gate) in (('erp_mark_setup_step', 'erp.mark_setup_step'),
                                      ('erp_dismiss_setup_step', 'erp.dismiss_setup_step'))) = 2,
    'erp_meta.public_write_allowance';
end;
$$;

create or replace function erp_test.assert_setup_walkthrough_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 12;
  v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _setup_walkthrough_result on commit drop as
    select * from erp_test.setup_walkthrough_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_total, v_passed, v_detail
    from _setup_walkthrough_result;
  drop table _setup_walkthrough_result;
  if v_passed < v_total then
    raise exception E'CLOVEERP_SETUP_WALKTHROUGH_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_SETUP_WALKTHROUGH_SUITE_INCOMPLETE: expected % cases, ran %', c_expected, v_total
      using errcode = 'P0001',
            detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('setup walkthrough: %s/%s cases passed', v_passed, v_total);
end;
$$;


-- ═════════════════════════════════════════════════════════════════════════════
-- 10. The words the walkthrough says
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Every string the panel, the button and the Settings home render as a ui()
-- literal, seeded through erp_ref.ui_key() so a tenant can rename them, as
-- supabase/ci/screen_strings.sh demands.

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'Screen string of the Settings walkthrough (src/components/erp/walkthrough.tsx and the Settings home).'
  from (values
    ('All screens, in order'),
    ('Bring back'),
    ('Everything in the setup order is done.'),
    ('Next screen'),
    ('Not yours to take'),
    ('On this screen'),
    ('Previous screen'),
    ('Refresh'),
    ('Set aside as not applying'),
    ('Set up, step by step'),
    ('Setup order'),
    ('The next thing to do'),
    ('The steps on this screen, in the order they are taken.'),
    ('This did not load.'),
    ('This screen is not in the setup order.'),
    ('Ticked as done'),
    ('Undo'),
    ('Waiting on'),
    ('Walkthrough')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 11. The generators, then the proofs
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_diagnostics_registered();
select erp.assert_guidance_sound();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_setup_walkthrough_actionable();
select erp_test.assert_setup_walkthrough_suite();
