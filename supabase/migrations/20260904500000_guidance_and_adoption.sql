-- =============================================================================
-- Part 22: guidance and adoption
--
-- Refusals already taught (§22.1): every refusal code resolves to what was
-- refused, why, and the next action, with the technical text folded away.
-- Adoption's registers existed. What Part 22 still lacked, and what this adds:
--
--   §22.2 contextual help against every screen, as a register the build
--   checks: erp_ref.help_topic, one row per screen, naming the navigation
--   key it belongs to, what the screen is for, the steps a person takes on
--   it, the next action, and the doors it offers. An organisation adds its
--   own local guidance through the resource layer (help.local.<screen>),
--   the same way it renames anything else, so the product's text and the
--   organisation's sit side by side and neither overwrites the other.
--   Configuration types gain a consequence: what happens above and below
--   the setting, not only its name.
--
--   §22.2 first-run guidance per role, not one tour: erp_ref.first_run_step
--   ties each step to the permission it needs, so a warehouse operative's
--   first day is the steps a warehouse operative can take, and a finance
--   manager's is different. Progress is per principal, and a step done stays
--   done.
--
--   §22.3 training scenarios as configuration: a named starting state, a
--   task, and a completion condition drawn from a register of completion
--   checks the build verifies against pg_proc. The product ships five; an
--   organisation adds its own from the same completions. A scenario is
--   refused in a live environment by the platform, and so — now — is the
--   demo seed, which until this migration was refused by a warning in a
--   guide.
--
--   §22.4 adoption signals, to the organisation about itself: approvals
--   ageing, change sets never promoted, imports never loaded, counts never
--   finished, invitations never claimed, scenarios never completed. Counts
--   and ages, never a person's name.
-- =============================================================================

-- ── Screens that had no navigation resource ───────────────────────────────────
--
-- Seven tiles fell back to their code-level title, which no organisation
-- could rename and the terminology report could not see. The help register
-- keys on the navigation key, so they get their rows here.

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('nav.overview', 'en', 'Home', null, 'Navigation label for the home screen.'),
  ('nav.finance_account_determination', 'en', 'Account determination', null,
   'Navigation label for the finance screen showing how documents find their nominal accounts.'),
  ('nav.master_data_classification', 'en', 'Classification and codes', null,
   'Navigation label for the master data screen showing classification axes, values and code templates.'),
  ('nav.master_data_item_supply', 'en', 'Product supply defaults', null,
   'Navigation label for the master data screen showing each product''s default suppliers and lead times.'),
  ('nav.logistics_release_areas', 'en', 'Marshalling areas', null,
   'Navigation label for the logistics screen showing marshalling areas and what is staged in them.'),
  ('nav.administration_onboarding', 'en', 'People and invitations', null,
   'Navigation label for the administration screen where people are invited and their invitations tracked.'),
  ('nav.administration_organisation', 'en', 'Organisation structure', null,
   'Navigation label for the administration screen showing companies, sites and departments.'),
  ('nav.administration_adoption', 'en', 'Guidance and adoption', null,
   'Navigation label for the administration screen showing contextual help, first-run guidance, training scenarios and adoption signals.')
on conflict (key, locale) do nothing;

-- ── Contextual help ──────────────────────────────────────────────────────────

create table if not exists erp_ref.help_topic (
  screen_path text primary key,
  nav_key     text not null,
  module_code text not null,
  summary     text not null,
  -- The steps a person takes on this screen, in order.
  steps       jsonb not null default '[]'::jsonb,
  next_action text,
  -- The public doors the screen offers. Checked against pg_proc.
  actions     text[] not null default '{}',
  check (jsonb_typeof(steps) = 'array')
);

comment on table erp_ref.help_topic is
  'Specification v1.2 §22.2. Contextual help per screen: what it is for, the '
  'steps taken on it, the next action, and the doors it offers. An '
  'organisation adds local guidance through the resource key '
  'help.local.<screen>. Checked by erp.assert_guidance_sound().';

select erp_meta.register_table('erp_ref', 'help_topic', 'product_content',
  'Part 22. Contextual help per screen, checked against navigation keys and doors.');

insert into erp_ref.help_topic (screen_path, nav_key, module_code, summary, steps, next_action, actions) values
  ('/', 'nav.overview', 'administration',
   'Where you are, what this account may do, and every screen it can reach. The launchpad is arranged the way the work runs: plan, source, make, move, sell, settle.',
   '["Check the company and site you are working in; narrowing them changes what is shown, not what is permitted.","Open a screen from the launchpad or the rail.","If you are new, follow your first-run guidance below the welcome."]',
   'Follow the first-run guidance for your role.',
   '{erp_seed_demo}'),
  ('/master-data', 'nav.master_data', 'master_data',
   'Business partners, products and units: the records everything else refers to.',
   '["Create a business partner or product, or maintain one.","Give a business partner its roles: customer, supplier.","Check duplicates and data quality findings before they spread."]',
   'Import in bulk from the Imports screen when there are many.',
   '{}'),
  ('/master-data/imports', 'nav.imports', 'master_data',
   'Bulk arrival of records and opening balances: staged, validated, previewed, loaded, and reversible as a unit.',
   '["Stage a batch of rows.","Validate it: every row is checked against the same rules a keyed entry faces.","Preview what it will do, then load.","Roll back a batch as a unit if it was wrong."]',
   'Opening balances have their own screen under Migration and cutover.',
   '{erp_stage_import,erp_validate_import,erp_preview_import,erp_load_import,erp_rollback_import}'),
  ('/master-data/classification', 'nav.master_data_classification', 'master_data',
   'Classification axes and their values, and the code templates that compose a product code from them.',
   '["Define an axis (family, grade) and its values.","Classify products against each axis.","Compose a code template from axes and a sequence."]',
   'Classify every product before relying on codes.',
   '{erp_upsert_classification_axis,erp_upsert_classification_value,erp_upsert_code_template,erp_classify_item}'),
  ('/master-data/item-supply', 'nav.master_data_item_supply', 'master_data',
   'Which suppliers supply each product, ranked, with lead times and minimums.',
   '["Set a default supplier for a purchased product.","Rank alternatives and record lead times.","Planning and purchasing read these defaults."]',
   'Run planning once defaults are in place.',
   '{erp_set_item_supplier}'),
  ('/procurement', 'nav.procurement', 'procurement',
   'Requisitions, purchase orders, receipts and matching.',
   '["Raise a requisition or a purchase order.","Receive against the order when goods arrive.","Match the invoice to the receipt; variances go to approval."]',
   'Receive goods as soon as they arrive; the receipt drives stock and finance.',
   '{}'),
  ('/inventory', 'module.inventory', 'inventory',
   'Stock by site and location, movements, counts, valuation and health.',
   '["Read stock positions and movements.","Raise and complete putaway and count tasks.","Adjust or write off with a reason; both post to the ledger."]',
   'Count regularly; a count that is approved posts the difference.',
   '{}'),
  ('/planning', 'module.planning', 'planning',
   'Forecasts, planning policy and the planning run that turns demand into proposals.',
   '["Set the planning policy per product.","Run planning for a site and horizon.","Firm the proposals you accept into orders."]',
   'Firm the proposals you accept.',
   '{}'),
  ('/production', 'module.production', 'production',
   'Works orders, release, issue, output and the batch record.',
   '["Raise a works order for a product with a bill of materials.","Release it, issue components, receive output.","The batch record and cost follow."]',
   'Release the works order when material is available.',
   '{}'),
  ('/sales', 'nav.sales', 'sales',
   'Quotations, sales orders, allocation, despatch and invoicing.',
   '["Raise a sales order for a customer.","Allocate stock and despatch it.","Invoice from the despatch."]',
   'Confirm the order; allocation and despatch follow from it.',
   '{}'),
  ('/logistics', 'module.logistics', 'logistics',
   'Shipments, carriers and the despatch process.',
   '["Plan a shipment from despatch-ready orders.","Confirm the carrier and despatch.","Track proof of delivery."]',
   'Plan shipments daily from what is ready.',
   '{}'),
  ('/logistics/release-areas', 'nav.logistics_release_areas', 'logistics',
   'Marshalling areas: where staged stock waits for despatch, and the rules for printing and ageing.',
   '["Create a marshalling area on a pickable location.","Stage picked stock into it.","Print is gated on the area''s rules; staged stock ages back to bulk."]',
   'Create one area per despatch door.',
   '{erp_upsert_release_area}'),
  ('/finance', 'module.finance', 'finance',
   'The nominal ledger, subledgers, periods and close.',
   '["Read the trial balance and the subledger reconciliation.","Post manual journals with a reason.","Close a period when it reconciles."]',
   'Reconcile the subledgers before closing a period.',
   '{}'),
  ('/finance/account-determination', 'nav.finance_account_determination', 'finance',
   'How each document finds its nominal accounts: posting classes, determination rules and the coverage report.',
   '["Read the coverage report: a document type with no path to an account is a finding.","Set the posting class on products and business partners.","Every rule is promoted, not typed."]',
   'Clear every coverage finding before going live.',
   '{}'),
  ('/quality', 'module.quality', 'quality',
   'Inspections, dispositions, batch release and recalls.',
   '["Inspect stock held in quarantine.","Disposition it: release, rework, reject.","A recall traces every batch forward and back."]',
   'Disposition quarantined stock promptly.',
   '{}'),
  ('/reporting', 'module.reporting', 'reporting',
   'Reports and KPIs over the organisation''s own data.',
   '["Run a report with parameters.","Pin a KPI.","Every run is recorded with the version and parameters it used."]',
   'Define a report version before sharing its figures.',
   '{}'),
  ('/reporting/reproducibility', 'nav.reporting_reproducibility', 'reporting',
   'Report versions, the governed view each reads, and every run with the parameters it used.',
   '["Create a version of a report against a governed view.","Promote it; runs record the version.","Re-run any past run reproducibly."]',
   'Version a report before its figures leave the organisation.',
   '{}'),
  ('/governance', 'nav.governance', 'administration',
   'Change sets: every configuration change, approved by a second person, promoted, and reversible.',
   '["A change set collects configuration changes.","Somebody other than its author approves it.","Promote it; roll it back if it was wrong."]',
   'Approve and promote the change sets the installers created.',
   '{}'),
  ('/administration/audit', 'nav.audit', 'administration',
   'The audit stream: every change, who made it, what it was before and after.',
   '["Filter by object, actor or action.","Read the before and after states.","The stream is append-only; nothing here is edited."]',
   null,
   '{}'),
  ('/administration/onboarding', 'nav.administration_onboarding', 'administration',
   'People: invite them, track invitations, see who has claimed theirs.',
   '["Invite a person by email.","They claim the invitation once, which makes them a principal.","Give them roles on the Permissions screen."]',
   'Invite a second administrator before going live.',
   '{erp_invite_principal}'),
  ('/administration/organisation', 'nav.administration_organisation', 'administration',
   'Companies, sites and departments: the structure everything is scoped by.',
   '["A company carries a ledger and a base currency.","A site belongs to one company and holds locations.","Departments route approvals."]',
   'Create the sites you operate before receiving stock.',
   '{}'),
  ('/administration/permissions', 'nav.administration_permissions', 'administration',
   'Roles and the permissions they carry; who holds which role, where.',
   '["Roles come from the installers and the packs.","Grant a role to a person, optionally scoped to a company or site.","Separation of duties findings show conflicting grants."]',
   'Grant the fewest roles that let a person do their work.',
   '{}'),
  ('/administration/configuration', 'nav.administration_configuration', 'administration',
   'Which modules are installed and what each setting means, with its consequence.',
   '["Install a module: its configuration arrives as a change set.","Read each setting''s consequence before changing it.","Changes are promoted, never typed into a live organisation."]',
   'Install the modules you use, then approve and promote them.',
   '{erp_seed_demo_configuration}'),
  ('/administration/packs', 'nav.administration_packs', 'administration',
   'Starter content packs: vocabularies, reason codes, states, tolerances and finance, applied as change sets.',
   '["Choose a preset that matches the organisation.","Apply the packs; each is a change set.","The acceptance suite says whether the result is complete."]',
   'Apply the base packs before configuring by hand.',
   '{}'),
  ('/administration/tenant', 'nav.tenant', 'administration',
   'The organisation itself: identity, environments, export, keys and deletion.',
   '["Export the organisation''s data.","Rotate the data key.","Deletion destroys the key; it is a deletion that deletes."]',
   null,
   '{}'),
  ('/administration/terminology', 'nav.terminology', 'administration',
   'Rename what the product calls things, and set the brand.',
   '["Override a term for this organisation.","Every screen resolves through the same keys.","Local guidance for a screen is a resource too: help.local.<screen>."]',
   'Rename the terms your people already use.',
   '{}'),
  ('/administration/commercial', 'nav.administration_commercial', 'administration',
   'The plan, subscription, entitlements against their limits, and usage meters.',
   '["Read the entitlements and where usage stands against each.","A limit reached is a refusal that names the plan."]',
   null,
   '{}'),
  ('/administration/accessibility', 'nav.administration_accessibility', 'administration',
   'The accessibility statement, generated from the WCAG 2.2 register and checked on every build.',
   '["Read the conformance and the known exceptions.","Report a barrier to your administrator."]',
   null,
   '{erp_accessibility_statement}'),
  ('/administration/erasure', 'nav.administration_erasure', 'administration',
   'Personal data: which columns hold it, and requests to erase a person, executed by a second administrator.',
   '["Request the erasure of a principal or a contact, with a reason.","Another administrator executes it.","The certificate says what was overwritten and what was redacted."]',
   null,
   '{erp_request_erasure,erp_execute_erasure,erp_refuse_erasure}'),
  ('/administration/adoption', 'nav.administration_adoption', 'administration',
   'Guidance and adoption: contextual help, first-run guidance per role, training scenarios, and where people are struggling.',
   '["Read the adoption signals: what is ageing, what was never finished.","Start a training scenario in a demo organisation.","Add a scenario of your own from the completion checks."]',
   'Start with the signal that has been ageing longest.',
   '{erp_start_training_scenario,erp_check_training_run,erp_upsert_training_scenario}'),
  ('/operations/assurance', 'nav.operations_assurance', 'administration',
   'Every assertion the build runs, run here against this organisation.',
   '["Read the diagnostics.","A finding names the object and the next action."]',
   null,
   '{}'),
  ('/operations/jobs', 'nav.operations_jobs', 'administration',
   'Scheduled jobs, their handlers, runs and failures.',
   '["Read what is due and what failed.","A failed run says why; fix the cause and re-run."]',
   null,
   '{}'),
  ('/operations/integrations', 'nav.operations_integrations', 'administration',
   'Adapters, message queues and external references.',
   '["Register an adapter.","Watch the outbox and inbox.","A failed message retries by policy and then says so."]',
   null,
   '{}'),
  ('/operations/continuity', 'nav.operations_continuity', 'administration',
   'What was promised about staying up, whether a drill has proved it, and what happened when it did not.',
   '["Read the objectives and the last drill.","Record an incident and its review."]',
   null,
   '{}'),
  ('/operations/devices', 'nav.operations_devices', 'inventory',
   'Scanners and terminals: sessions, the action queue, scan rules.',
   '["Register a device at a site.","Open a session from the device.","Apply your queued actions; conflicts say why."]',
   'Register a device and set a scan rule per step.',
   '{erp_register_device,erp_upsert_scan_rule,erp_drain_device_actions}'),
  ('/operations/output', 'nav.operations_output', 'administration',
   'Output templates, printers, requests with their renders and deliveries, and suppressed addresses.',
   '["Version a template.","Register a printer.","Every request records its render and delivery."]',
   null,
   '{}'),
  ('/operations/cutover', 'nav.operations_cutover', 'master_data',
   'Opening balances as at a date, whether each load reconciles, parallel-run figures, and which domains are cut over.',
   '["Stage opening balances with the control total the extract was taken with.","Validate, preview, load; read the reconciliation.","Record the legacy figure against ours.","Cut the domain over — somebody other than the loader."]',
   'Load stock first, then the ledgers, then the trial balance.',
   '{erp_stage_opening_balances,erp_record_parallel_run_figure,erp_cut_over_domain,erp_revert_cutover}')
on conflict (screen_path) do update set
  nav_key = excluded.nav_key, module_code = excluded.module_code, summary = excluded.summary,
  steps = excluded.steps, next_action = excluded.next_action, actions = excluded.actions;

-- A setting's consequence, not only its name.
alter table erp_ref.config_type add column if not exists consequence text;

update erp_ref.config_type set consequence = c.consequence
  from (values
    ('production.issue_method', 'Backflush: components are consumed when output is booked, so stock on hand is right only after output. Manual: an operator issues before output, so stock is right as work proceeds. Scanned: each issue is a scan, so traceability is exact and the operation is slower.'),
    ('stock.shelf_life_minimum', 'Above the percentage a batch is accepted; below it the receipt, transfer or despatch is refused and the batch stays where it is. Set it too high and good stock is refused; too low and short-dated stock reaches customers.'),
    ('stock.allocation_policy', 'FEFO allocates the batch expiring first; FIFO the oldest received. Allowing a split fills an order from several batches; forbidding it leaves an order short until one batch can fill it.'),
    ('stock.reservation_ageing', 'Above the hours an unconsumed reservation is released back to available, so nothing is held forever; below it the reservation stands. Staged stock older than the second limit returns to bulk.'),
    ('sales.credit_control', 'At the limit an order is held for credit release rather than confirmed; above the overdue threshold no further supply is confirmed until the debt is cleared. Set nothing and every order is confirmed regardless of debt.'),
    ('sales.backorder_policy', 'Permit: the short line stays open and ships later. Refuse: the line is cancelled and the customer told. Ship what there is: the line closes short. Per channel, because a trade customer and a consumer expect different answers.'),
    ('quality.quarantine_defaults', 'Receipts of the named accounting codes land in quarantine rather than available stock; stock still there after the days named becomes a finding on the quality screen.'),
    ('approval.reapproval_tolerance', 'A change within both the percentage and the absolute keeps the approval; a change beyond either voids it and the chain runs again. A small percentage of a large order is still a large sum, which is why both apply.')
  ) as c(code, consequence)
 where erp_ref.config_type.code = c.code;

-- ── First-run guidance per role ──────────────────────────────────────────────

create table if not exists erp_ref.first_run_step (
  guide_code      text not null,
  seq             smallint not null,
  screen_path     text not null references erp_ref.help_topic (screen_path),
  -- The step is offered to whoever holds this. A guide is the set of steps
  -- its holder can take, not a tour everybody gets.
  permission_code text not null references erp_ref.permission (code),
  title           text not null,
  why             text not null,
  primary key (guide_code, seq)
);

comment on table erp_ref.first_run_step is
  '§22.2. First-run guidance per role, as steps tied to the permission each '
  'needs: a person sees the steps they can take, in order, and marks them done.';

select erp_meta.register_table('erp_ref', 'first_run_step', 'product_content',
  'Part 22. First-run guidance steps per role, tied to permissions.');

insert into erp_ref.first_run_step (guide_code, seq, screen_path, permission_code, title, why) values
  ('administrator', 1, '/administration/onboarding', 'administration.users',
   'Invite a second administrator', 'Going live needs two: after it, the author of a change may no longer approve it.'),
  ('administrator', 2, '/administration/configuration', 'administration.configure',
   'Install the modules you use', 'Each installer creates a change set with the module''s configuration; nothing is typed into a live organisation.'),
  ('administrator', 3, '/administration/packs', 'administration.configure',
   'Apply the starter packs', 'Vocabularies, reason codes, states and tolerances arrive as change sets; the acceptance suite says when the set is complete.'),
  ('administrator', 4, '/governance', 'administration.promote',
   'Approve and promote', 'A change set is promoted by somebody other than its author. Until it is, the configuration is not in force.'),
  ('administrator', 5, '/administration/permissions', 'administration.roles',
   'Give people roles', 'The fewest roles that let each person do their work; separation-of-duties findings show where two conflict.'),
  ('administrator', 6, '/administration/terminology', 'administration.configure',
   'Name things your way', 'Every screen resolves through the same keys; rename the terms your people already use.'),
  ('finance', 1, '/finance', 'finance.read',
   'Read the trial balance and the subledger reconciliation', 'The two must agree at all times; a difference is a finding, not a memory.'),
  ('finance', 2, '/finance/account-determination', 'finance.configure',
   'Clear every account determination finding', 'A document type with no path to an account cannot post.'),
  ('finance', 3, '/operations/cutover', 'master_data.import',
   'Load opening balances as at a date', 'Stock, then the sales and purchase ledgers, then the trial balance; migration clearing nets to nothing when they agree.'),
  ('finance', 4, '/finance', 'finance.close_period',
   'Close the first period', 'A close is refused while anything blocking is open; the report says what.'),
  ('warehouse', 1, '/inventory', 'inventory.read',
   'Read stock by site and location', 'Positions, movements and what is committed; the balance is derived from movements, never edited.'),
  ('warehouse', 2, '/inventory', 'inventory.move',
   'Complete a putaway task', 'Receiving to a storage location; the task records who moved what.'),
  ('warehouse', 3, '/inventory', 'inventory.count',
   'Count a location', 'A count that is approved posts the difference; a count outside tolerance goes to approval.'),
  ('warehouse', 4, '/operations/devices', 'inventory.move',
   'Apply your queued device actions', 'Actions captured offline apply in the order they were captured; a conflict says why.'),
  ('sales', 1, '/sales', 'sales.order',
   'Raise a sales order', 'Confirming it allocates stock; despatch and invoice follow from it.'),
  ('sales', 2, '/logistics', 'logistics.read',
   'Follow it to despatch', 'Shipments are planned from despatch-ready orders.'),
  ('sales', 3, '/logistics/release-areas', 'logistics.plan',
   'Set up a marshalling area', 'Staged stock waits here; print is gated on the area''s rules.'),
  ('procurement', 1, '/master-data/item-supply', 'master_data.write',
   'Set default suppliers', 'Planning and purchasing read them; a product with none cannot be proposed.'),
  ('procurement', 2, '/procurement', 'procurement.order',
   'Raise a purchase order', 'Sent to the supplier; the receipt and the invoice match against it.'),
  ('procurement', 3, '/procurement', 'procurement.receive',
   'Receive against it', 'The receipt drives stock and the goods-received-not-invoiced balance.'),
  ('planning', 1, '/planning', 'planning.read',
   'Set the planning policy per product', 'Reorder point, lot size, lead time: the policy decides what the run proposes.'),
  ('planning', 2, '/planning', 'planning.run',
   'Run planning', 'Demand becomes proposals; firm the ones you accept.'),
  ('production', 1, '/production', 'production.order',
   'Raise a works order', 'For a product with a bill of materials; release it when material is available.'),
  ('production', 2, '/production', 'production.execute',
   'Issue components and receive output', 'The batch record and the cost follow from what was issued and received.'),
  ('quality', 1, '/quality', 'quality.inspect',
   'Inspect quarantined stock', 'Receipts of the configured codes land in quarantine; stock left too long is a finding.'),
  ('quality', 2, '/quality', 'quality.disposition',
   'Disposition it', 'Release, rework or reject; a release makes the batch available.'),
  ('reporting', 1, '/reporting', 'reporting.read',
   'Run a report', 'Every run records the version and parameters it used, so it can be re-run.'),
  ('reporting', 2, '/reporting/reproducibility', 'reporting.define',
   'Version a report', 'A version is promoted; figures that leave the organisation carry it.')
on conflict (guide_code, seq) do update set
  screen_path = excluded.screen_path, permission_code = excluded.permission_code,
  title = excluded.title, why = excluded.why;

create table if not exists erp.first_run_progress (
  tenant_id   uuid not null references erp.tenant (id) on delete cascade,
  app_user_id uuid not null,
  guide_code  text not null,
  seq         smallint not null,
  done_at     timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  primary key (tenant_id, app_user_id, guide_code, seq),
  foreign key (guide_code, seq) references erp_ref.first_run_step (guide_code, seq)
);

comment on table erp.first_run_progress is
  '§22.2. Which first-run steps each principal has marked done. A step done stays done.';

select erp_meta.register_table('erp', 'first_run_progress', 'tenant_scoped',
  'Part 22. Per-principal first-run guidance progress.');

-- The steps for the caller: those whose permission they hold, with done flags.
create or replace function erp.first_run_guide()
returns table (guide_code text, seq smallint, screen_path text, permission_code text,
               title text, why text, done_at timestamptz)
language sql
stable
security invoker
set search_path = ''
as $$
  select s.guide_code, s.seq, s.screen_path, s.permission_code, s.title, s.why, p.done_at
    from erp_ref.first_run_step s
    left join erp.first_run_progress p
      on p.tenant_id = erp.current_tenant_id() and p.app_user_id = erp.current_principal_id()
     and p.guide_code = s.guide_code and p.seq = s.seq
   where erp.has_permission(s.permission_code, null, null, null, erp.current_principal_id())
   order by s.guide_code, s.seq
$$;

create or replace function erp.mark_first_run_step(p_guide_code text, p_seq smallint, p_done boolean default true)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_me     uuid := erp.current_principal_id();
  v_perm   text;
begin
  select s.permission_code into v_perm from erp_ref.first_run_step s
   where s.guide_code = p_guide_code and s.seq = p_seq;
  if v_perm is null then
    raise exception 'ERPWARE_UNKNOWN_STEP: %/% is not a first-run step', p_guide_code, p_seq
      using errcode = '23503';
  end if;
  -- The step is the caller's to mark only if it was theirs to take.
  perform erp.authorise(v_perm, null, null, null, 'first_run_step', null);

  if p_done then
    insert into erp.first_run_progress (tenant_id, app_user_id, guide_code, seq)
    values (v_tenant, v_me, p_guide_code, p_seq)
    on conflict do nothing;
  else
    delete from erp.first_run_progress
     where tenant_id = v_tenant and app_user_id = v_me and guide_code = p_guide_code and seq = p_seq;
  end if;
end;
$$;

-- ── Training scenarios ────────────────────────────────────────────────────────

create table if not exists erp_ref.scenario_completion (
  code         text primary key,
  sql_function text not null,
  description  text not null
);

comment on table erp_ref.scenario_completion is
  '§22.3. The completion conditions a training scenario may use: each names '
  'an erp function (p_since timestamptz) returning boolean, checked against '
  'pg_proc by the build. An organisation builds its own scenarios from these.';

select erp_meta.register_table('erp_ref', 'scenario_completion', 'product_content',
  'Part 22. Completion checks a training scenario may name.');

create or replace function erp.scenario_principal_invited(p_since timestamptz)
returns boolean language sql stable security invoker set search_path = '' as $$
  select exists (select 1 from erp.app_user u
                  where u.tenant_id = erp.current_tenant_id() and u.kind = 'person'
                    -- A colleague: somebody other than the person practising.
                    and u.id is distinct from erp.current_principal_id()
                    and u.created_at >= p_since)
$$;

create or replace function erp.scenario_goods_receipt_posted(p_since timestamptz)
returns boolean language sql stable security invoker set search_path = '' as $$
  select exists (select 1 from erp.stock_movement m
                  where m.tenant_id = erp.current_tenant_id()
                    and m.movement_type = 'goods_receipt' and m.recorded_at >= p_since)
$$;

create or replace function erp.scenario_count_approved(p_since timestamptz)
returns boolean language sql stable security invoker set search_path = '' as $$
  select exists (select 1 from erp.count_task t
                  where t.tenant_id = erp.current_tenant_id()
                    and t.status in ('approved', 'posted') and t.updated_at >= p_since)
$$;

create or replace function erp.scenario_sales_order_raised(p_since timestamptz)
returns boolean language sql stable security invoker set search_path = '' as $$
  select exists (select 1 from erp.document d
                  join erp.document_type dt on dt.id = d.document_type_id
                 where d.tenant_id = erp.current_tenant_id()
                   and dt.code = 'sales_order' and d.created_at >= p_since)
$$;

create or replace function erp.scenario_opening_stock_loaded(p_since timestamptz)
returns boolean language sql stable security invoker set search_path = '' as $$
  select exists (select 1 from erp.import_batch b
                  where b.tenant_id = erp.current_tenant_id()
                    and b.object_type = 'opening_stock' and b.status = 'loaded'
                    and b.loaded_at >= p_since)
$$;

insert into erp_ref.scenario_completion (code, sql_function, description) values
  ('principal_invited', 'scenario_principal_invited', 'A person has been invited since the scenario started.'),
  ('goods_receipt_posted', 'scenario_goods_receipt_posted', 'A goods receipt movement has been recorded since the scenario started.'),
  ('count_approved', 'scenario_count_approved', 'A count task has been approved or posted since the scenario started.'),
  ('sales_order_raised', 'scenario_sales_order_raised', 'A sales order has been raised since the scenario started.'),
  ('opening_stock_loaded', 'scenario_opening_stock_loaded', 'An opening stock batch has been loaded since the scenario started.')
on conflict (code) do update set sql_function = excluded.sql_function, description = excluded.description;

create table if not exists erp_ref.training_scenario (
  code            text primary key,
  module_code     text not null,
  title           text not null,
  starting_state  text not null,
  task            text not null,
  completion_code text not null references erp_ref.scenario_completion (code),
  permission_code text not null references erp_ref.permission (code),
  seq             smallint not null
);

comment on table erp_ref.training_scenario is
  '§22.3. Training scenarios the product ships: a named starting state, a '
  'task, and a completion condition. Started only where the environment is '
  'not live.';

select erp_meta.register_table('erp_ref', 'training_scenario', 'product_content',
  'Part 22. The training scenarios the product ships.');

insert into erp_ref.training_scenario
  (code, module_code, title, starting_state, task, completion_code, permission_code, seq)
values
  ('invite_a_colleague', 'administration', 'Invite a colleague',
   'A demo organisation with you as its administrator.',
   'Invite a person from the People and invitations screen. The invitation is claimed once and makes them a principal.',
   'principal_invited', 'administration.users', 1),
  ('receive_a_delivery', 'procurement', 'Receive a delivery',
   'A demo organisation with a sent purchase order for 500 units.',
   'Receive the goods against the purchase order and post the receipt. Stock and the goods-received-not-invoiced balance follow.',
   'goods_receipt_posted', 'procurement.receive', 2),
  ('count_a_location', 'inventory', 'Count a location',
   'A demo organisation with stock in a receiving location and a count programme.',
   'Raise count tasks, count the location, and approve the count. The difference posts.',
   'count_approved', 'inventory.count', 3),
  ('raise_a_sales_order', 'sales', 'Raise a sales order',
   'A demo organisation with a customer and finished goods in stock.',
   'Raise a sales order for the customer and confirm it. Allocation follows.',
   'sales_order_raised', 'sales.order', 4),
  ('load_opening_stock', 'master_data', 'Load opening stock',
   'A demo organisation with products, a site and a location.',
   'Stage a batch of opening stock with its control total, validate, preview and load it, then read the reconciliation.',
   'opening_stock_loaded', 'master_data.import', 5)
on conflict (code) do update set
  module_code = excluded.module_code, title = excluded.title,
  starting_state = excluded.starting_state, task = excluded.task,
  completion_code = excluded.completion_code, permission_code = excluded.permission_code,
  seq = excluded.seq;

-- An organisation's own scenarios, from the same completions.
create table if not exists erp.training_scenario (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant (id) on delete cascade,
  code            text not null,
  title           text not null,
  starting_state  text not null,
  task            text not null,
  completion_code text not null references erp_ref.scenario_completion (code),
  permission_code text not null references erp_ref.permission (code),
  status          erp.record_status not null default 'active',
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  unique (tenant_id, id),
  unique (tenant_id, code)
);

comment on table erp.training_scenario is
  '§22.3. Training scenarios an organisation builds for itself, from the '
  'product''s completion checks.';

select erp_meta.register_table('erp', 'training_scenario', 'tenant_scoped',
  'Part 22. An organisation''s own training scenarios.');

create table if not exists erp.training_run (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references erp.tenant (id) on delete cascade,
  scenario_code text not null,
  -- product: erp_ref.training_scenario; organisation: erp.training_scenario.
  scenario_source text not null check (scenario_source in ('product', 'organisation')),
  app_user_id   uuid not null,
  started_at    timestamptz not null default now(),
  checked_at    timestamptz,
  completed_at  timestamptz,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  unique (tenant_id, id)
);

comment on table erp.training_run is
  '§22.3. One person''s attempt at a scenario: started, checked, completed.';

select erp_meta.register_table('erp', 'training_run', 'tenant_scoped',
  'Part 22. Training scenario runs per principal.');

create or replace function erp.upsert_training_scenario(
  p_code text, p_title text, p_starting_state text, p_task text,
  p_completion_code text, p_permission_code text)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
begin
  perform erp.authorise('administration.configure', null, null, null, 'training_scenario', null);
  if not exists (select 1 from erp_ref.scenario_completion c where c.code = p_completion_code) then
    raise exception 'ERPWARE_UNKNOWN_COMPLETION: % is not a completion check the product has', p_completion_code
      using errcode = '23503',
      hint = 'erp_ref.scenario_completion lists them; a scenario can only end on one of these.';
  end if;
  insert into erp.training_scenario (
    tenant_id, code, title, starting_state, task, completion_code, permission_code)
  values (v_tenant, p_code, p_title, p_starting_state, p_task, p_completion_code, p_permission_code)
  on conflict (tenant_id, code) do update set
    title = excluded.title, starting_state = excluded.starting_state, task = excluded.task,
    completion_code = excluded.completion_code, permission_code = excluded.permission_code,
    status = 'active', updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function erp.start_training_scenario(p_code text)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_me     uuid := erp.current_principal_id();
  v_perm   text;
  v_source text;
  v_id     uuid;
begin
  -- §22.3: refused in a live environment by the platform, not by a guide.
  if erp.environment_is_live() then
    raise exception
      'ERPWARE_TRAINING_IN_LIVE: this organisation is live; a training scenario is '
      'practised in a demo organisation, where nothing is real'
      using errcode = '42501',
      hint = 'Seed a demo organisation from the home screen and start the scenario there.';
  end if;

  select s.permission_code, 'product' into v_perm, v_source
    from erp_ref.training_scenario s where s.code = p_code;
  if v_perm is null then
    select s.permission_code, 'organisation' into v_perm, v_source
      from erp.training_scenario s
     where s.tenant_id = v_tenant and s.code = p_code and s.status = 'active';
  end if;
  if v_perm is null then
    raise exception 'ERPWARE_UNKNOWN_SCENARIO: % is not a training scenario', p_code
      using errcode = '23503';
  end if;

  perform erp.authorise(v_perm, null, null, null, 'training_scenario', null);

  insert into erp.training_run (tenant_id, scenario_code, scenario_source, app_user_id)
  values (v_tenant, p_code, v_source, v_me)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function erp.check_training_run(p_run_id uuid)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_me     uuid := erp.current_principal_id();
  run      erp.training_run%rowtype;
  v_fn     text;
  v_perm   text;
  v_done   boolean;
begin
  select * into run from erp.training_run r
   where r.tenant_id = v_tenant and r.id = p_run_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_RUN: %', p_run_id using errcode = '23503';
  end if;
  if run.app_user_id <> v_me then
    raise exception 'ERPWARE_NOT_YOUR_RUN: a scenario is checked by the person practising it'
      using errcode = '42501';
  end if;

  if run.scenario_source = 'product' then
    select c.sql_function, s.permission_code into v_fn, v_perm
      from erp_ref.training_scenario s join erp_ref.scenario_completion c on c.code = s.completion_code
     where s.code = run.scenario_code;
  else
    select c.sql_function, s.permission_code into v_fn, v_perm
      from erp.training_scenario s join erp_ref.scenario_completion c on c.code = s.completion_code
     where s.tenant_id = v_tenant and s.code = run.scenario_code;
  end if;
  perform erp.authorise(v_perm, null, null, null, 'training_run', p_run_id);

  execute format('select erp.%I($1)', v_fn) into v_done using run.started_at;

  update erp.training_run
     set checked_at = now(),
         completed_at = case when v_done then coalesce(completed_at, now()) else completed_at end,
         updated_at = now()
   where id = p_run_id;

  return v_done;
end;
$$;

-- ── The demo seed, refused in a live environment by the platform ─────────────
--
-- erp.seed_demo() creates a fresh demo organisation and never touched a live
-- one. The two seeds that write into the current organisation did not ask.
-- Re-emitted from 20260830110335 and 20260830134027 with the refusal first.

create or replace function erp.seed_demo_operations()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_actor uuid := erp.current_principal_id();
  v_site uuid; v_entity uuid; v_ccy char(3); v_notes jsonb := '[]'::jsonb;
  v_supplier uuid; v_customer uuid; v_rm uuid; v_fg uuid;
  v_po uuid; v_receipt uuid; v_so uuid; v_line uuid; v_wo uuid;
  v_recv uuid; v_prog text; v_n integer; v_seeded boolean;
begin
  -- §22.3: the demo seed is refused in a live environment by the platform.
  if erp.environment_is_live() then
    raise exception
      'ERPWARE_DEMO_IN_LIVE: this organisation is live; demonstration history is '
      'not written into a live ledger'
      using errcode = '42501',
      hint = 'Seed a demo organisation from the home screen instead.';
  end if;

  perform erp.authorise('master_data.write', null, null, null, 'tenant', v_tenant);

  select s.id, s.entity_id, l.currency into v_site, v_entity, v_ccy
    from erp.site s
    join erp.ledger l on l.tenant_id = s.tenant_id and l.entity_id = s.entity_id
   where s.tenant_id = v_tenant and s.status = 'active'::erp.record_status
   order by s.code limit 1;

  if v_site is null then
    select s.id, s.entity_id into v_site, v_entity from erp.site s
     where s.tenant_id = v_tenant and s.status = 'active'::erp.record_status
     order by s.code limit 1;
  end if;

  if v_site is null then
    return jsonb_build_object('ok', false, 'notes',
      jsonb_build_array('There is no active site yet, so no operational history could be built.'));
  end if;

  if exists (select 1 from erp.document d
              where d.tenant_id = v_tenant and d.their_reference = 'DEMO-SEED-BILL') then
    return jsonb_build_object('ok', true, 'site', v_site, 'notes',
      jsonb_build_array('Demonstration history already runs end to end for this company; nothing was duplicated.'));
  end if;

  v_seeded := exists (select 1 from erp.document d
                       where d.tenant_id = v_tenant and d.their_reference = 'DEMO-SEED');

  if not v_seeded then
    begin
      perform erp.seed_demo_master_data(v_tenant, v_actor);
      v_notes := v_notes || to_jsonb('Demo master data is in place.'::text);
    exception when others then
      v_notes := v_notes || to_jsonb(('Master data could not be seeded: ' || sqlerrm)::text);
    end;

    insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, created_by, updated_by)
    select v_tenant, v_site, x.code, x.name, x.lt::erp.location_type, x.pickable, v_actor, v_actor
      from (values ('RECV','Goods in','receiving',false),('BULK','Bulk store','bulk',false),
                   ('PICK','Pick face','pick',true),('QC','Quarantine','quarantine',false),
                   ('DESP','Despatch bay','despatch',false)) as x(code,name,lt,pickable)
     where not exists (select 1 from erp.location l
                        where l.tenant_id = v_tenant and l.site_id = v_site and l.code = x.code);

    select id into v_recv from erp.location where tenant_id = v_tenant and site_id = v_site and code = 'RECV';

    select p.id into v_supplier from erp.party p
      join erp.party_role r on r.tenant_id = p.tenant_id and r.party_id = p.id
     where p.tenant_id = v_tenant and r.role_kind = 'supplier' order by p.code limit 1;
    select p.id into v_customer from erp.party p
      join erp.party_role r on r.tenant_id = p.tenant_id and r.party_id = p.id
     where p.tenant_id = v_tenant and r.role_kind = 'customer' order by p.code limit 1;

    select id into v_rm from erp.item
     where tenant_id = v_tenant and status = 'active'::erp.record_status
     order by (code not like 'RM-%'), code limit 1;
    select id into v_fg from erp.item
     where tenant_id = v_tenant and status = 'active'::erp.record_status
       and (v_rm is null or id <> v_rm)
     order by (code not like 'FG-%'), code limit 1;
    v_fg := coalesce(v_fg, v_rm);

    if v_supplier is null or v_customer is null or v_rm is null then
      return jsonb_build_object('ok', false, 'notes', v_notes
        || to_jsonb('A supplier, a customer and at least one item are needed before history can be built.'::text));
    end if;

    begin
      v_notes := v_notes || to_jsonb(erp.seed_demo_bom(v_fg, v_rm, v_site));
    exception when others then
      v_notes := v_notes || to_jsonb(('Bill of materials was skipped: ' || sqlerrm)::text);
    end;

    begin
      v_po := erp.create_document('purchase_order', v_entity, v_site, v_supplier, current_date, v_ccy, 'DEMO-SEED');
      perform erp.add_document_line(v_po, v_rm, 500, 1250, 'Demo raw material order');
      perform erp.transition_document(v_po, 'submit');
      perform erp.transition_document(v_po, 'approve');
      perform erp.transition_document(v_po, 'send');
      v_notes := v_notes || to_jsonb('Raised and sent a purchase order for 500 units.'::text);
    exception when others then
      v_po := null;
      v_notes := v_notes || to_jsonb(('Purchase order was skipped: ' || sqlerrm)::text);
    end;

    if v_po is not null then
      begin
        v_receipt := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'DEMO-SEED');
        select dl.id into v_line from erp.document_line dl where dl.document_id = v_po order by dl.line_no limit 1;
        perform erp.receive_against(v_receipt, v_line, 500);
        perform erp.transition_document(v_receipt, 'post');
        v_notes := v_notes || to_jsonb('Received 500 units into stock.'::text);
      exception when others then
        v_notes := v_notes || to_jsonb(('Receipt was skipped: ' || sqlerrm)::text);
      end;
    end if;

    begin
      v_n := erp.raise_putaway_tasks(v_site);
      v_notes := v_notes || to_jsonb((v_n || ' putaway task(s) raised.')::text);
    exception when others then
      v_notes := v_notes || to_jsonb(('Putaway was skipped: ' || sqlerrm)::text);
    end;

    begin
      v_wo := erp.raise_works_order(v_fg, v_site, 50, 'assembly'::erp.works_order_kind, current_date + 7);
      perform erp.release_works_order(v_wo, true);
      perform erp.issue_to_works_order(v_wo, v_rm, 100, null, v_recv);
      perform erp.receive_works_order_output(v_wo, 40, null, v_recv);
      v_notes := v_notes || to_jsonb('Ran a works order for 50, received 40 so far.'::text);
    exception when others then
      v_notes := v_notes || to_jsonb(('Production history was skipped: ' || sqlerrm)::text);
    end;

    begin
      v_so := erp.create_document('sales_order', v_entity, v_site, v_customer, current_date, v_ccy, 'DEMO-SEED');
      perform erp.add_document_line(v_so, v_fg, 20, 9900, 'Demo customer order', current_date + 5);
      perform erp.transition_document(v_so, 'submit');
      perform erp.transition_document(v_so, 'approve');
      v_notes := v_notes || to_jsonb('Confirmed a customer order for 20 units.'::text);
    exception when others then
      v_notes := v_notes || to_jsonb(('Sales history was skipped: ' || sqlerrm)::text);
    end;

    begin
      select code into v_prog from erp.count_programme
       where tenant_id = v_tenant and status = 'active'::erp.record_status order by code limit 1;
      if v_prog is null then
        v_notes := v_notes || to_jsonb('No counting programme is configured, so no counts were raised.'::text);
      else
        v_n := erp.raise_count_tasks(v_prog);
        v_notes := v_notes || to_jsonb((v_n || ' count task(s) raised from ' || v_prog || '.')::text);
      end if;
    exception when others then
      v_notes := v_notes || to_jsonb(('Counting was skipped: ' || sqlerrm)::text);
    end;

    begin
      perform erp.run_planning(v_site, 90);
      v_notes := v_notes || to_jsonb('Planning run completed for the next 90 days.'::text);
    exception when others then
      v_notes := v_notes || to_jsonb(('Planning was skipped: ' || sqlerrm)::text);
    end;
  else
    v_notes := v_notes || to_jsonb('Operating history already existed; adding billing and settlement to it.'::text);
  end if;

  -- Despatch, invoice, and a part payment, so finance has a full cycle to read.
  v_notes := v_notes || erp.seed_demo_billing();

  return jsonb_build_object('ok', true, 'site', v_site, 'notes', v_notes);
end $$;

create or replace function public.erp_seed_demo_configuration()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_axis_f uuid;
  v_axis_g uuid;
  v_site   uuid;
  v_loc    uuid;
  v_item   uuid;
  v_party  uuid;
  v_items  int := 0;
  v_areas  int := 0;
  v_sups   int := 0;
  r        record;
begin
  -- §22.3: the demo seed is refused in a live environment by the platform.
  if erp.environment_is_live() then
    raise exception
      'ERPWARE_DEMO_IN_LIVE: this organisation is live; demonstration configuration '
      'is not written over a live one'
      using errcode = '42501',
      hint = 'Seed a demo organisation from the home screen instead.';
  end if;

  perform erp.authorise('administration.configure');

  -- Classification: a family axis with a small hierarchy, and a grade axis.
  perform public.erp_upsert_classification_axis(
    'FAMILY', 'Product family', true, null, 10, null);
  perform public.erp_upsert_classification_axis(
    'GRADE', 'Grade', false, null, 20, null);

  select a.id into v_axis_f from erp.classification_axis a
   where a.tenant_id = v_tenant and a.code = 'FAMILY' and a.status = 'active';
  select a.id into v_axis_g from erp.classification_axis a
   where a.tenant_id = v_tenant and a.code = 'GRADE' and a.status = 'active';

  perform public.erp_upsert_classification_value(v_axis_f, 'AMB', 'Ambient goods', 'AMB', null, null);
  perform public.erp_upsert_classification_value(v_axis_f, 'CHL', 'Chilled goods', 'CHL', null, null);
  perform public.erp_upsert_classification_value(v_axis_f, 'PKG', 'Packaging', 'PKG', null, null);
  perform public.erp_upsert_classification_value(v_axis_g, 'STD', 'Standard', 'STD', null, null);
  perform public.erp_upsert_classification_value(v_axis_g, 'PRM', 'Premium', 'PRM', null, null);

  -- A code template that composes from those axes.
  perform public.erp_upsert_code_template(
    'DEMO-ITEM', 'Demo item code',
    '[{"kind":"literal","value":"D"},
      {"kind":"axis","axis":"FAMILY","length":3},
      {"kind":"axis","axis":"GRADE","length":3},
      {"kind":"sequence","length":4}]'::jsonb,
    null, 'upper', null);

  -- Classify whatever items exist, so the gaps report has something to say.
  for r in select i.id, row_number() over (order by i.code) as n
             from erp.item i
            where i.tenant_id = v_tenant and i.status <> 'archived'
            limit 12
  loop
    begin
      perform public.erp_classify_item(r.id, v_axis_f,
        (select v.id from erp.classification_value v
          where v.tenant_id = v_tenant and v.axis_id = v_axis_f
            and v.code = (array['AMB','CHL','PKG'])[1 + (r.n % 3)]), null);
      perform public.erp_classify_item(r.id, v_axis_g,
        (select v.id from erp.classification_value v
          where v.tenant_id = v_tenant and v.axis_id = v_axis_g
            and v.code = (array['STD','PRM'])[1 + (r.n % 2)]), null);
      v_items := v_items + 1;
    exception when others then null;
    end;
  end loop;

  -- Default suppliers for purchased items, ranked, with lead times.
  for r in select i.id as item_id, p.id as party_id,
                  row_number() over (order by i.code, p.code) as n
             from erp.item i
             cross join lateral (
               select p2.id, p2.code from erp.party p2
                where p2.tenant_id = v_tenant and p2.status = 'active'
                order by p2.code limit 2) p
            where i.tenant_id = v_tenant and i.status = 'active'
            limit 10
  loop
    begin
      perform public.erp_set_item_supplier(
        r.item_id, r.party_id, null,
        case when r.n % 2 = 1 then 1 else 2 end,
        r.n % 2 = 1, null, true, null,
        7 * (1 + (r.n % 3)), 10, 'Demo configuration preset');
      v_sups := v_sups + 1;
    exception when others then null;
    end;
  end loop;

  -- One release area per site, on a pickable location where there is one.
  for r in select s.id as site_id, s.code from erp.site s
            where s.tenant_id = v_tenant and s.status = 'active'
            order by s.code limit 2
  loop
    select l.id into v_loc from erp.location l
     where l.tenant_id = v_tenant and l.site_id = r.site_id
       and coalesce(l.is_pickable, true) and not coalesce(l.is_blocked, false)
     order by l.code limit 1;

    begin
      perform public.erp_upsert_release_area(
        r.site_id, 'DEMO-REL', 'Demo release area', v_loc, 'pull',
        null, null, null, 0, 500, 24, true);
      v_areas := v_areas + 1;
    exception when others then null;
    end;
  end loop;

  perform erp.append_event('configuration.preset_applied', 'tenant', v_tenant,
    jsonb_build_object('items_classified', v_items, 'suppliers', v_sups,
                       'release_areas', v_areas));

  return jsonb_build_object('items_classified', v_items, 'supplier_defaults', v_sups,
                            'release_areas', v_areas, 'axes', 2, 'code_templates', 1);
end;
$$;

-- ── Adoption signals ─────────────────────────────────────────────────────────

create or replace function erp.adoption_report()
returns table (signal text, count bigint, oldest_days integer, guidance text)
language sql
stable
security invoker
set search_path = ''
as $$
  select 'approvals pending more than three days', count(*),
         max(extract(day from now() - a.requested_at))::integer,
         'Approvers may be unassigned or away; check the chain''s steps and delegation.'
    from erp.approval_request a
   where a.tenant_id = erp.current_tenant_id() and a.status = 'pending'
     and a.requested_at < now() - interval '3 days'
  union all
  select 'change sets drafted more than seven days ago and never promoted', count(*),
         max(extract(day from now() - c.created_at))::integer,
         'Configuration that is not promoted is not in force; approve and promote, or cancel.'
    from erp.change_set c
   where c.tenant_id = erp.current_tenant_id() and c.status in ('draft', 'ready')
     and c.created_at < now() - interval '7 days'
  union all
  select 'imports staged more than seven days ago and never loaded', count(*),
         max(extract(day from now() - b.created_at))::integer,
         'A batch that stalled at validation usually has rows the file needs fixing for; the findings say which.'
    from erp.import_batch b
   where b.tenant_id = erp.current_tenant_id() and b.status in ('received', 'validated', 'previewed')
     and b.created_at < now() - interval '7 days'
  union all
  select 'count tasks open more than seven days', count(*),
         max(extract(day from now() - t.created_at))::integer,
         'Counts left open are stock nobody has confirmed; complete them or cancel the programme run.'
    from erp.count_task t
   where t.tenant_id = erp.current_tenant_id() and t.status = 'open'
     and t.created_at < now() - interval '7 days'
  union all
  select 'invitations unclaimed after seven days', count(*),
         max(extract(day from now() - i.created_at))::integer,
         'The person may not have received it; resend or revoke.'
    from erp.invitation i
   where i.tenant_id = erp.current_tenant_id() and i.claimed_at is null and i.revoked_at is null
     and i.created_at < now() - interval '7 days'
  union all
  select 'training scenarios started more than seven days ago and never completed', count(*),
         max(extract(day from now() - r.started_at))::integer,
         'A scenario nobody finishes is a task the guidance does not explain well enough.'
    from erp.training_run r
   where r.tenant_id = erp.current_tenant_id() and r.completed_at is null
     and r.started_at < now() - interval '7 days'
$$;

comment on function erp.adoption_report is
  '§22.4. Where people are struggling, to the organisation about itself: '
  'counts and ages of what is pending, stalled or never finished. Never a '
  'person''s name, never another organisation''s data.';

-- ── The register agrees with the catalogue ────────────────────────────────────

create or replace function erp.guidance_register_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  select 'help topic names a navigation key with no base-locale resource', h.screen_path, h.nav_key
    from erp_ref.help_topic h
   where not exists (select 1 from erp_ref.resource r where r.key = h.nav_key and r.locale = 'en')
  union all
  select 'help topic names a module that does not exist', h.screen_path, h.module_code
    from erp_ref.help_topic h
   where not exists (select 1 from erp_ref.module m where m.code = h.module_code)
  union all
  select 'help topic names a door that does not exist', h.screen_path, a.fn
    from erp_ref.help_topic h, unnest(h.actions) a(fn)
   where not exists (select 1 from pg_catalog.pg_proc p
                      where p.pronamespace = 'public'::regnamespace and p.proname = a.fn)
  union all
  select 'help topic has no steps', h.screen_path, ''
    from erp_ref.help_topic h where jsonb_array_length(h.steps) = 0
  union all
  select 'a setting has no consequence', c.code, 'erp_ref.config_type.consequence'
    from erp_ref.config_type c where coalesce(c.consequence, '') = ''
  union all
  select 'a completion check names a function that does not exist', c.code, c.sql_function
    from erp_ref.scenario_completion c
   where not exists (select 1 from pg_catalog.pg_proc p
                      where p.pronamespace = 'erp'::regnamespace and p.proname = c.sql_function
                        and pg_catalog.pg_get_function_identity_arguments(p.oid) = 'p_since timestamp with time zone'
                        and p.prorettype = 'boolean'::regtype)
  union all
  select 'a first-run guide has no step for its first sequence', s.guide_code, ''
    from (select distinct guide_code from erp_ref.first_run_step) s
   where not exists (select 1 from erp_ref.first_run_step x where x.guide_code = s.guide_code and x.seq = 1)
  union all
  select 'the demo seed is not refused in a live environment', f.name, ''
    from (values ('seed_demo_operations', 'erp'::regnamespace), ('erp_seed_demo_configuration', 'public'::regnamespace)) f(name, ns)
   where not exists (select 1 from pg_catalog.pg_proc p
                      where p.pronamespace = f.ns and p.proname = f.name
                        and p.prosrc like '%environment_is_live%')
  union all
  select 'a training scenario is not refused in a live environment', 'erp.start_training_scenario', ''
   where not exists (select 1 from pg_catalog.pg_proc p
                      where p.pronamespace = 'erp'::regnamespace and p.proname = 'start_training_scenario'
                        and p.prosrc like '%environment_is_live%')
$$;

create or replace function erp.assert_guidance_sound()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare v_count integer; v_detail text; v_topics integer; v_steps integer; v_guides integer; v_scen integer;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail
    from erp.guidance_register_report();
  if v_count > 0 then
    raise exception 'ERPWARE_GUIDANCE_REGISTER_UNSOUND: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;
  select count(*) into v_topics from erp_ref.help_topic;
  select count(*), count(distinct guide_code) into v_steps, v_guides from erp_ref.first_run_step;
  select count(*) into v_scen from erp_ref.training_scenario;
  return format('guidance: %s help topics, %s first-run steps across %s guides, %s training scenarios, demo seed refused in live',
                v_topics, v_steps, v_guides, v_scen);
end;
$$;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('guidance_register', 'Guidance register sound', 'assertion', 'platform',
   'erp', 'assert_guidance_sound', '', 'guidance_register_report', '',
   'Every help topic names a real navigation key, module and doors; every setting states its consequence; every completion check exists; the demo seed and training scenarios are refused in a live environment.',
   true, 66)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  detail_function = excluded.detail_function;

-- ── Doors ─────────────────────────────────────────────────────────────────────

create or replace function public.erp_help_topic(p_screen_path text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare v_key text;
begin
  perform erp.require_tenant_id();
  v_key := 'help.local.' || trim(both '.' from replace(p_screen_path, '/', '.'));
  return (select jsonb_build_object(
      'screen_path', h.screen_path, 'nav_key', h.nav_key,
      'title', coalesce(erp.text(h.nav_key), h.screen_path),
      'module_code', h.module_code, 'summary', h.summary, 'steps', h.steps,
      'next_action', h.next_action, 'actions', to_jsonb(h.actions),
      -- The organisation's own guidance, if it has written any.
      'local_note', nullif(erp.text(v_key), v_key), 'local_key', v_key)
    from erp_ref.help_topic h where h.screen_path = p_screen_path);
end;
$$;

create or replace function public.erp_help_topics()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform erp.authorise('administration.read');
  return coalesce((select jsonb_agg(jsonb_build_object(
      'screen_path', h.screen_path, 'nav_key', h.nav_key,
      'title', coalesce(erp.text(h.nav_key), h.screen_path),
      'module_code', h.module_code, 'summary', h.summary, 'steps', h.steps,
      'next_action', h.next_action, 'actions', to_jsonb(h.actions)) order by h.screen_path)
    from erp_ref.help_topic h), '[]'::jsonb);
end;
$$;

create or replace function public.erp_first_run_guide()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform erp.require_tenant_id();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'guide_code', g.guide_code, 'seq', g.seq, 'screen_path', g.screen_path,
      'permission_code', g.permission_code, 'title', g.title, 'why', g.why,
      'done_at', g.done_at) order by g.guide_code, g.seq)
    from erp.first_run_guide() g), '[]'::jsonb);
end;
$$;

create or replace function public.erp_mark_first_run_step(p_guide_code text, p_seq integer, p_done boolean default true)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.mark_first_run_step(p_guide_code, p_seq::smallint, p_done);
  return jsonb_build_object('guide_code', p_guide_code, 'seq', p_seq, 'done', p_done);
end;
$$;

create or replace function public.erp_training_scenarios()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare v_tenant uuid;
begin
  v_tenant := erp.require_tenant_id();
  return coalesce((
    select jsonb_agg(x order by x ->> 'source' desc, (x ->> 'seq')::integer, x ->> 'code') from (
      select jsonb_build_object('code', s.code, 'source', 'product', 'seq', s.seq,
               'module_code', s.module_code, 'title', s.title,
               'starting_state', s.starting_state, 'task', s.task,
               'completion_code', s.completion_code,
               'completion', c.description, 'permission_code', s.permission_code,
               'may_start', erp.has_permission(s.permission_code, null, null, null, erp.current_principal_id())) as x
        from erp_ref.training_scenario s join erp_ref.scenario_completion c on c.code = s.completion_code
      union all
      select jsonb_build_object('code', s.code, 'source', 'organisation', 'seq', 0,
               'module_code', null, 'title', s.title,
               'starting_state', s.starting_state, 'task', s.task,
               'completion_code', s.completion_code,
               'completion', c.description, 'permission_code', s.permission_code,
               'may_start', erp.has_permission(s.permission_code, null, null, null, erp.current_principal_id()))
        from erp.training_scenario s join erp_ref.scenario_completion c on c.code = s.completion_code
       where s.tenant_id = v_tenant and s.status = 'active') t), '[]'::jsonb);
end;
$$;

create or replace function public.erp_training_runs()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare v_tenant uuid;
begin
  v_tenant := erp.require_tenant_id();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'run_id', r.id, 'scenario_code', r.scenario_code, 'scenario_source', r.scenario_source,
      'mine', r.app_user_id = erp.current_principal_id(),
      'started_at', r.started_at, 'checked_at', r.checked_at, 'completed_at', r.completed_at)
      order by r.started_at desc)
    from erp.training_run r where r.tenant_id = v_tenant), '[]'::jsonb);
end;
$$;

create or replace function public.erp_start_training_scenario(p_code text)
returns jsonb
language sql
set search_path = ''
as $$
  select jsonb_build_object('run_id', erp.start_training_scenario(p_code))
$$;

create or replace function public.erp_check_training_run(p_run_id uuid)
returns jsonb
language sql
set search_path = ''
as $$
  select jsonb_build_object('completed', erp.check_training_run(p_run_id))
$$;

create or replace function public.erp_upsert_training_scenario(
  p_code text, p_title text, p_starting_state text, p_task text,
  p_completion_code text, p_permission_code text)
returns jsonb
language sql
set search_path = ''
as $$
  select jsonb_build_object('scenario_id', erp.upsert_training_scenario(
    p_code, p_title, p_starting_state, p_task, p_completion_code, p_permission_code))
$$;

create or replace function public.erp_scenario_completions()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform erp.require_tenant_id();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'code', c.code, 'description', c.description) order by c.code)
    from erp_ref.scenario_completion c), '[]'::jsonb);
end;
$$;

create or replace function public.erp_adoption_signals()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform erp.authorise('administration.read');
  return coalesce((select jsonb_agg(jsonb_build_object(
      'signal', a.signal, 'count', a.count, 'oldest_days', a.oldest_days, 'guidance', a.guidance))
    from erp.adoption_report() a), '[]'::jsonb);
end;
$$;

revoke all on function
  public.erp_help_topic(text),
  public.erp_help_topics(),
  public.erp_first_run_guide(),
  public.erp_mark_first_run_step(text, integer, boolean),
  public.erp_training_scenarios(),
  public.erp_training_runs(),
  public.erp_start_training_scenario(text),
  public.erp_check_training_run(uuid),
  public.erp_upsert_training_scenario(text, text, text, text, text, text),
  public.erp_scenario_completions(),
  public.erp_adoption_signals()
  from public, anon;

grant execute on function
  public.erp_help_topic(text),
  public.erp_help_topics(),
  public.erp_first_run_guide(),
  public.erp_mark_first_run_step(text, integer, boolean),
  public.erp_training_scenarios(),
  public.erp_training_runs(),
  public.erp_start_training_scenario(text),
  public.erp_check_training_run(uuid),
  public.erp_upsert_training_scenario(text, text, text, text, text, text),
  public.erp_scenario_completions(),
  public.erp_adoption_signals()
  to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_mark_first_run_step', 'erp.mark_first_run_step',
   '§22.2. Marks one of the caller''s own first-run steps done or not. Gates on the step''s own permission: a step is the caller''s to mark only if it was theirs to take.'),
  ('erp_start_training_scenario', 'erp.start_training_scenario',
   '§22.3. Starts a training scenario for the caller. Refused in a live environment; gates on the scenario''s permission.'),
  ('erp_check_training_run', 'erp.check_training_run',
   '§22.3. Evaluates the completion check of the caller''s own run. Gates on the scenario''s permission.'),
  ('erp_upsert_training_scenario', 'erp.upsert_training_scenario',
   '§22.3. Creates or maintains one of the organisation''s own scenarios from the product''s completion checks. Gates on administration.configure.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

-- ── The suite ─────────────────────────────────────────────────────────────────

create or replace function erp_test.guidance_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r   record;
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();
  v_second uuid; v_tok text; res jsonb;
  v_run uuid; v_ok boolean; v_msg text; v_n integer;
begin
  select * into r from erp.provision_tenant(
    'zzgui', 'Guidance', 'admin@zzgui.test', 'Guidance Admin');
  insert into auth.users (id, email) values (a1, 'admin@zzgui.test'), (a2, 'viewer@zzgui.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);

  begin
    v_msg := erp.assert_guidance_sound(); v_ok := true;
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 160);
  end;
  return query select 'every help topic, first-run step, scenario and completion check resolves',
    v_ok and v_msg like 'guidance: % help topics, % first-run steps across % guides, 5 training scenarios, demo seed refused in live', v_msg;

  -- ── Contextual help ───────────────────────────────────────────────────────

  res := public.erp_help_topic('/administration/erasure');
  return query select 'a screen''s help carries its title, steps, next action and doors',
    res ->> 'title' = 'Personal data and erasure'
    and jsonb_array_length(res -> 'steps') = 3
    and res -> 'actions' @> '["erp_execute_erasure"]'::jsonb
    and res ->> 'local_note' is null
    and res ->> 'local_key' = 'help.local.administration.erasure',
    res ->> 'title';

  -- Local guidance is configuration: outside the bootstrap window it arrives
  -- through a promoted change set like any other override.
  perform erp_test.reopen_bootstrap_window(r.tenant_id);
  insert into erp.resource_override (tenant_id, key, locale, value)
  values (r.tenant_id, 'help.local.administration.erasure', 'en',
          'Our data protection officer is Priya; ask her before executing.');
  perform erp_test.close_bootstrap_window(r.tenant_id);
  res := public.erp_help_topic('/administration/erasure');
  return query select 'an organisation''s local guidance sits beside the product''s, through the resource layer',
    res ->> 'local_note' like 'Our data protection officer%'
    and res ->> 'summary' like 'Personal data:%',
    res ->> 'local_note';

  return query select 'every setting states its consequence',
    not exists (select 1 from erp_ref.config_type c where coalesce(c.consequence, '') = ''),
    format('%s settings', (select count(*) from erp_ref.config_type));

  -- ── Training scenarios ────────────────────────────────────────────────────

  -- Scenarios are practised where nothing is real: the organisation is taken
  -- out of live for this section, as a demo organisation would be.
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp_test.reopen_bootstrap_window(r.tenant_id);
  v_run := erp.start_training_scenario('invite_a_colleague');
  return query select 'a scenario starts and is not complete before the task is done',
    not erp.check_training_run(v_run)
    and (select t.completed_at from erp.training_run t where t.id = v_run) is null,
    'invite a colleague: nobody invited yet';

  perform public.erp_invite_principal('newbie@zzgui.test', 'New Person');
  v_ok := erp.check_training_run(v_run);
  return query select 'and completes when the completion check is met',
    v_ok
    and (select t.completed_at from erp.training_run t where t.id = v_run) is not null,
    'a person was invited after the run started';

  perform erp.upsert_training_scenario('our_receipt', 'Receive our way',
    'The demo organisation.', 'Receive a delivery the way our goods-in does it.',
    'goods_receipt_posted', 'procurement.receive');
  return query select 'an organisation builds its own scenario from the product''s completion checks',
    exists (select 1 from jsonb_array_elements(public.erp_training_scenarios()) x
             where x ->> 'code' = 'our_receipt' and x ->> 'source' = 'organisation'),
    'our_receipt, ending on goods_receipt_posted';

  begin
    perform erp.upsert_training_scenario('bad', 'Bad', 'x', 'y', 'telepathy', 'procurement.receive');
    v_ok := false; v_msg := 'a scenario ended on a completion the product does not have';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_COMPLETION%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'but only from those completions', v_ok, v_msg;

  -- ── First-run guidance per role ───────────────────────────────────────────

  select count(*) into v_n from erp.first_run_guide();
  return query select 'an administrator sees every step, because they hold every permission',
    v_n = (select count(*) from erp_ref.first_run_step),
    format('%s steps', v_n);

  perform erp.mark_first_run_step('administrator', 1::smallint);
  return query select 'a step marked done stays done, for this person',
    (select g.done_at is not null from erp.first_run_guide() g where g.guide_code = 'administrator' and g.seq = 1)
    and (select count(*) from erp.first_run_guide() g where g.done_at is not null) = 1,
    'administrator step 1 done';

  -- A provisioned organisation carries one role, administrator. The second
  -- person needs one that reads and nothing else.
  perform erp_test.reopen_bootstrap_window(r.tenant_id);
  insert into erp.role (tenant_id, code, name, description, status)
  values (r.tenant_id, 'viewer', 'Viewer', 'Reads the organisation; changes nothing.', 'active');
  insert into erp.role_permission (tenant_id, role_id, permission_code)
  select r.tenant_id, ro.id, 'inventory.read'
    from erp.role ro where ro.tenant_id = r.tenant_id and ro.code = 'viewer';
  perform erp_test.close_bootstrap_window(r.tenant_id);

  res := public.erp_invite_principal('viewer@zzgui.test', 'Only Viewer');
  v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform erp.grant_role(v_second, 'viewer', null, null, 'reads only');
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  select count(*) into v_n from erp.first_run_guide() g where g.guide_code = 'administrator';
  return query select 'a person who cannot configure sees no administrator steps',
    v_n = 0
    and not exists (select 1 from erp.first_run_guide() g where g.done_at is not null),
    format('%s administrator steps for a viewer; nothing marked done for them', v_n);

  begin
    perform erp.mark_first_run_step('administrator', 2::smallint);
    v_ok := false; v_msg := 'a viewer marked an administrator''s step';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PERMISSION_DENIED%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'nor mark one done', v_ok, v_msg;

  -- ── Somebody else's run ───────────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  begin
    perform erp.check_training_run(v_run);
    v_ok := false; v_msg := 'somebody else checked the run';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NOT_YOUR_RUN%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a run is checked by the person practising it', v_ok, v_msg;

  -- ── Refused in a live environment, by the platform ────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  update erp.environment set is_live = true where tenant_id = r.tenant_id and is_self;
  begin
    perform erp.start_training_scenario('invite_a_colleague');
    v_ok := false; v_msg := 'a scenario started in a live organisation';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_TRAINING_IN_LIVE%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a training scenario is refused in a live environment', v_ok, v_msg;

  begin
    perform erp.seed_demo_operations();
    v_ok := false; v_msg := 'demo history was written into a live organisation';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_DEMO_IN_LIVE%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'and so is the demo seed, by the platform rather than a guide', v_ok, v_msg;

  begin
    perform public.erp_seed_demo_configuration();
    v_ok := false; v_msg := 'demo configuration was written over a live organisation';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_DEMO_IN_LIVE%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'the demo configuration too', v_ok, v_msg;
  update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;

  -- ── Adoption signals ──────────────────────────────────────────────────────

  -- created_at is frozen by the attribution trigger, so an old invitation is
  -- written old rather than aged: a second, nine-day-old invitation for the
  -- newcomer, unclaimed.
  insert into erp.invitation (tenant_id, app_user_id, token_digest, expires_at, created_at)
  select r.tenant_id, u.id, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'),
         now() - interval '2 days', now() - interval '9 days'
    from erp.app_user u where u.tenant_id = r.tenant_id and u.email = 'newbie@zzgui.test';
  update erp.training_run set started_at = now() - interval '8 days'
   where tenant_id = r.tenant_id and id <> v_run;
  return query select 'the adoption report counts what is ageing and never names a person',
    (select a.count from erp.adoption_report() a where a.signal like 'invitations unclaimed%') = 1
    and (select a.oldest_days from erp.adoption_report() a where a.signal like 'invitations unclaimed%') >= 8
    and (select count(*) from erp.adoption_report()) = 6
    and (select string_agg(a.signal || a.guidance, ' ') from erp.adoption_report() a) not like '%newbie%',
    format('%s signals; one invitation unclaimed for 9 days', (select count(*) from erp.adoption_report()));

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('erp.purge_tenant_id', r.tenant_id::text, true);
  delete from erp.tenant where id = r.tenant_id;
  perform set_config('erp.purge_tenant_id', '', true);
  delete from auth.users where id in (a1, a2);
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = r.tenant_id)
    and not exists (select 1 from erp.training_run t where t.tenant_id = r.tenant_id)
    and not exists (select 1 from erp.first_run_progress p where p.tenant_id = r.tenant_id),
    'runs and progress go with the organisation';
end;
$$;

create or replace function erp_test.assert_guidance_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _guidance_result on commit drop as
    select * from erp_test.guidance_suite();

  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not passed)
    into v_total, v_passed, v_detail
    from _guidance_result;

  if v_passed < v_total then
    raise exception E'ERPWARE_GUIDANCE_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('guidance: %s/%s', v_passed, v_total);
end;
$$;

-- ── The generators, then the assertions ──────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_configuration_promotable();
select erp.assert_no_dead_configuration();
select erp.assert_diagnostics_registered();
select erp.assert_product_decisions_enforced();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_guidance_sound();
select erp_test.assert_guidance_suite();
