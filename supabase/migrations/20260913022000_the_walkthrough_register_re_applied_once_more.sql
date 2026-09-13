-- The walkthrough register, re-applied once more.
--
-- 20260913021000 exists because 20260913020000 was edited after it was
-- pushed. It was then edited itself, twice, while the edits it describes were
-- still being made: once to record a second edit, once to re-apply a third.
-- A migration is written once, and the rule holds for a repair as it holds
-- for what it repairs. So this file re-applies the setup order, the step
-- register and the evidence function as they now stand, and the register
-- names it as the repair of 20260913021000. Nothing here changes a
-- definition; it states the current one a third time, which is the price of
-- editing in place instead of forward, paid so that the next reader does not
-- have to wonder which version an environment holds.

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
  ('warehouse.layout', '/inventory/warehouse', 1, 'Lay out each site', 'Goods-in, bulk, pick and despatch locations, down to the bin where stock is tracked.', 'Add a location', 'erp_create_location', 'administration.configure', true, array['organisation.site']::text[]),
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
  ('output.sender', '/operations/output', 3, 'Register a sending domain', 'Email leaves from your own domain once its DNS is verified; until then nothing is sent.', 'Register a sending domain', 'erp_upsert_sender_identity', 'administration.integrate', true, '{}'::text[]),
  ('output.verify', '/operations/output', 4, 'Record the DNS verification', 'SPF, DKIM and DMARC, verified and recorded; the platform will not send from a domain it cannot prove.', 'Record DNS verification', 'erp_record_sender_verification', 'administration.integrate', true, array['output.sender']::text[]),
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
    from (select (select count(*) from erp.dimension_value v join erp.dimension d on d.tenant_id = v.tenant_id and d.id = v.dimension_id, t where v.tenant_id = t.id and d.code = 'COST_CENTRE' and v.status = 'active') as n) x
  union all
  select 'dimensions.declare'::text, (n >= 1), (case when n = 0 then 'no dimension beyond cost centre yet' when n = 1 then 'one dimension beyond cost centre' else n || ' dimensions beyond cost centre' end)
    from (select (select count(*) from erp.dimension d, t where d.tenant_id = t.id and d.status = 'active' and d.code <> 'COST_CENTRE') as n) x
  union all
  select 'dimensions.values'::text, (n >= 1), (case when n = 0 then 'no dimension value yet' when n = 1 then 'one dimension value' else n || ' dimension values' end)
    from (select (select count(*) from erp.dimension_value v join erp.dimension d on d.tenant_id = v.tenant_id and d.id = v.dimension_id, t where v.tenant_id = t.id and d.code <> 'COST_CENTRE' and v.status = 'active') as n) x
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

select erp.assert_setup_walkthrough_actionable();
select erp_test.assert_setup_walkthrough_suite();
