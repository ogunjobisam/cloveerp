-- =============================================================================
-- 20260906139000  Every door has a home
-- -----------------------------------------------------------------------------
-- Specification v1.6 Part 5 and Part 22. The public API had 543 doors and the
-- application named 455 of them; nothing said what the other eighty-eight were
-- for. Some were the worker's, the device client's or the build's; some were
-- reached by an integration under a credential; some were reachable from a
-- SQL client and nowhere else, which for a product whose claim is that every
-- capability is on a screen is a claim not kept.
--
-- What changes:
--
--   * The screens (committed with this file): every door a person uses in a
--     week now has a screen or an action — mass change, staging an import,
--     batch and line amendment, linking documents, committing an allocation,
--     opening-balance reconciliation, a new /finance/dimensions screen, reason
--     codes and change-set submission on the configuration screen, units on
--     master data, incident organisations and support-action logging in the
--     console, ambiguous-command reconciliation on the integrations screen,
--     and the doors Phase 8's earlier files built: order behaviours and
--     drop-ship, forecast events and adjustments, scenarios and pegging,
--     consolidation and elimination, settlement statements.
--   * erp_meta.api_only_door — the register for the rest: each door with the
--     caller it exists for (worker, ci, device, integration,
--     platform_internal, suite_evidence, pending_screen) and the reason; a
--     pending screen names the path it is intended for.
--   * erp.assert_doors_have_a_home(names) — the build hands it the list of
--     doors the application names (supabase/ci/app_doors.sh, step "Every
--     door has a home"); a door that is neither named nor registered fails
--     the build, so does a register row for a door that is named (stale) or
--     that does not exist. erp.door_home_report() shows the register on the
--     console.
--   * Every new door is in the help register (erp_ref.help_topic.actions) on
--     the screen that carries it, so erp.assert_guidance_sound() reads it;
--     /finance/dimensions gets its topic; the 292 strings the new screens
--     say get their resource rows so a tenant can rename them.
--
-- Proof: erp_test.door_register_suite() (6 cases, wrapper pinned); the
-- guidance assertion; the resource coverage assertions; the build step.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The register
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_meta.api_only_door (
  function_name        text primary key check (function_name ~ '^erp_[a-z0-9_]+$'),
  caller               text not null check (caller in ('worker', 'ci', 'device', 'integration', 'platform_internal', 'suite_evidence', 'pending_screen')),
  intended_screen_path text,
  reason               text not null check (length(btrim(reason)) >= 20),
  registered_at        timestamptz not null default now(),
  constraint api_only_door_pending_has_path check (caller <> 'pending_screen' or intended_screen_path is not null)
);

select erp_meta.register_table('erp_meta', 'api_only_door', 'platform_internal',
  'The public doors no screen names, each with the caller it exists for and why. erp.assert_doors_have_a_home() refuses a door that is neither named by the application nor registered here, and a row for a door that is named or does not exist.');

comment on table erp_meta.api_only_door is
  'Specification v1.6 Part 5. A public door either has a screen or a row '
  'here. The build extracts every erp_* name the application uses and calls '
  'erp.assert_doors_have_a_home() with the list; a door with neither fails '
  'the build. pending_screen is the honest backlog: the door exists, the '
  'screen does not yet, and the path says where it will go.';

insert into erp_meta.api_only_door (function_name, caller, intended_screen_path, reason) values
  ('erp_seed_demo_operations', 'ci', null,
   'Seeds the demonstration organisation''s operating history; supabase/ci/seed_demo.sql and the tenant screen''s seed button reach it through erp_seed_demo, which is named.'),
  ('erp_platform_ensure_schedule', 'ci', null,
   'Run once on a host with pg_cron by the platform owner after setting the dispatch secret (supabase/ops/README.md); the schedule is machinery, not a button.'),
  ('erp_platform_record_restore_drill', 'ci', null,
   'Written by .github/workflows/restore_drill.yml after it restores a dump and proves it; the drill records itself, a person does not.'),
  ('erp_chart_alternative', 'ci', null,
   'The chart-alternative report the console reads through erp_platform_diagnostics, which runs it by name from erp_meta.diagnostic_check.'),
  ('erp_part5_coverage', 'ci', null,
   'The Part 5 coverage report the console reads through erp_platform_diagnostics; the register itself is read by docs/build_counts.sh.'),
  ('erp_scan', 'device', null,
   'The device client''s one door for a barcode; the /device route posts scans through erp_record_device_action and the drain, and this is the direct form the device kit calls.'),
  ('erp_analytics_read', 'integration', null,
   'The analytics contract: an external process reads a governed view under a credential erp_issue_analytics_credential() issued. A screen would be a person pretending to be an integration.'),
  ('erp_put_protected_value', 'integration', null,
   'Stores a credential value the worker reads by reference (credential_ref); set by the platform owner from a shell, never typed on a screen where it would be seen.'),
  ('erp_read_protected_value', 'integration', null,
   'Read by the worker at dispatch to resolve a credential_ref; a screen that showed it would be the leak the store exists to prevent.'),
  ('erp_tenant_state', 'platform_internal', null,
   'The organisation''s lifecycle state, read by the shell''s session bootstrap through erp_session, which is named.'),
  ('erp_vocabularies', 'platform_internal', null,
   'Every vocabulary the product ships, read by the terminology tooling and the docs build; the terminology screen reads the resolved strings through erp_resources.'),
  ('erp_refusals', 'platform_internal', null,
   'The refusal register in a locale, read by the docs build and the terminology tooling; screens show a refusal when it happens, through the error layer.'),
  ('erp_notice_periods', 'platform_internal', null,
   'The notice periods the platform commits to, read by the continuity report the continuity screen renders through erp_platform_continuity.'),
  ('erp_email_readiness', 'platform_internal', null,
   'Whether the organisation can send email, read by the platform sweep and by the runbook (supabase/ops/README.md) before email is switched on; a screen would only repeat the runbook''s check.'),
  ('erp_platform_enquiries', 'pending_screen', '/platform',
   'Website enquiries the contact form stored; the console''s enquiries panel is the intended home and is not built yet.'),
  ('erp_platform_erase_enquiry', 'pending_screen', '/platform',
   'Erases one website enquiry on request; belongs beside the enquiries panel the console does not have yet.')
on conflict (function_name) do update
  set caller = excluded.caller, intended_screen_path = excluded.intended_screen_path, reason = excluded.reason;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The report and the assertion
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.door_home_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- A row for a door that does not exist.
  select 'the register names a door that does not exist', a.function_name, a.reason
    from erp_meta.api_only_door a
   where not exists (select 1 from erp.door_manifest() m where m.door = a.function_name)
  union all
  -- The backlog, so the console shows it.
  select 'a door is waiting for its screen', a.function_name,
         format('intended for %s: %s', a.intended_screen_path, a.reason)
    from erp_meta.api_only_door a
   where a.caller = 'pending_screen'
$$;
revoke all on function erp.door_home_report() from public, anon, authenticated;

create or replace function erp.assert_doors_have_a_home(p_doors text[])
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_named    integer := coalesce(cardinality(p_doors), 0);
  v_homeless text[];
  v_stale    text[];
  v_missing  text[];
  v_api      integer;
  v_pending  integer;
begin
  if v_named = 0 then
    raise exception 'CLOVEERP_APP_NAMES_NO_DOORS: the list of door names is empty'
      using errcode = '22023',
            hint = 'supabase/ci/app_doors.sh extracts every erp_* literal from src; an empty list means the extraction found nothing, which is not a pass.';
  end if;

  select array_agg(m.door order by m.door) into v_homeless
    from erp.door_manifest() m
   where not (m.door = any (p_doors))
     and not exists (select 1 from erp_meta.api_only_door a where a.function_name = m.door);
  if v_homeless is not null then
    raise exception E'CLOVEERP_DOOR_HAS_NO_HOME: % door(s) are named by no screen and registered for no caller:\n  %',
      cardinality(v_homeless), array_to_string(v_homeless, E'\n  ')
      using errcode = 'P0001',
            hint = 'Give the door a screen in src, or a row in erp_meta.api_only_door saying who calls it and why (pending_screen with the intended path is allowed).';
  end if;

  select array_agg(a.function_name order by a.function_name) into v_stale
    from erp_meta.api_only_door a
   where a.function_name = any (p_doors);
  if v_stale is not null then
    raise exception E'CLOVEERP_API_ONLY_DOOR_IS_NAMED: % registered door(s) are now named by a screen; the row is stale:\n  %',
      cardinality(v_stale), array_to_string(v_stale, E'\n  ')
      using errcode = 'P0001',
            hint = 'Delete the erp_meta.api_only_door row: the door has a home.';
  end if;

  select array_agg(a.function_name order by a.function_name) into v_missing
    from erp_meta.api_only_door a
   where not exists (select 1 from erp.door_manifest() m where m.door = a.function_name);
  if v_missing is not null then
    raise exception E'CLOVEERP_API_ONLY_DOOR_MISSING: % registered door(s) do not exist:\n  %',
      cardinality(v_missing), array_to_string(v_missing, E'\n  ')
      using errcode = 'P0001',
            hint = 'Delete the erp_meta.api_only_door row, or restore the door it names.';
  end if;

  select count(*) filter (where a.caller <> 'pending_screen'), count(*) filter (where a.caller = 'pending_screen')
    into v_api, v_pending
    from erp_meta.api_only_door a;

  return format('doors: %s named by the application, %s api-only, %s waiting for a screen; every door has a home',
                v_named, v_api, v_pending);
end;
$$;
revoke all on function erp.assert_doors_have_a_home(text[]) from public, anon, authenticated;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('door_register', 'Every door has a home', 'report', 'platform',
   'door_home_report', '', null, '',
   'The public doors no screen names, each with the caller it exists for; a row for a door that does not exist, and the doors still waiting for their screen. The build proves the rest: erp.assert_doors_have_a_home() refuses a door that is neither named by the application nor registered.',
   false, (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name, blurb = excluded.blurb;

insert into erp_meta.check_run_exemption (schema_name, function_name, driven_by, rationale) values
  ('erp', 'assert_doors_have_a_home', null,
   'Takes the door names supabase/ci/app_doors.sh extracts from the application source; only the build can know what the application names, and it calls this with that list after erp.assert_app_doors_exist().')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;
insert into erp_meta.diagnostic_exemption (schema_name, function_name, rationale) values
  ('erp', 'assert_doors_have_a_home',
   'Takes the list of door names the application source contains. A console button has no such list; the build extracts it and calls this. The console reads erp.door_home_report() instead.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The help register knows the new doors
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.help_topic (screen_path, nav_key, module_code, summary, steps, next_action, actions) values
  ('/finance/dimensions', 'nav.finance_dimensions', 'finance',
   'Analysis dimensions: their values, how a posting derives them from the document, and which combinations an account allows.',
   '["Declare a dimension and its values; a department creates its own.",
     "Give it a derivation over the posting''s facts, or leave it to the posting rule and the document.",
     "Write a combination rule where an account may not carry certain values together.",
     "Preview a document before it posts to see what its lines would be stamped with."]'::jsonb,
   'Require the dimensions an account must carry, so a line without them is refused rather than analysed as nothing.',
   array['erp_upsert_dimension', 'erp_upsert_dimension_value', 'erp_set_account_dimension_requirements',
         'erp_upsert_dimension_rule', 'erp_dimension_values', 'erp_preview_dimensions',
         'erp_dimensions', 'erp_dimension_rules'])
on conflict (screen_path) do update
  set nav_key = excluded.nav_key, module_code = excluded.module_code, summary = excluded.summary,
      steps = excluded.steps, next_action = excluded.next_action, actions = excluded.actions;

create or replace function erp_meta.add_help_actions(p_screen_path text, p_actions text[])
returns void
language plpgsql
set search_path = ''
as $$
begin
  update erp_ref.help_topic h
     set actions = (select array_agg(distinct a order by a) from unnest(h.actions || p_actions) a)
   where h.screen_path = p_screen_path;
  if not found then
    raise exception 'CLOVEERP_NO_HELP_TOPIC: % has no help topic to carry its actions', p_screen_path
      using errcode = '23503', hint = 'Insert the topic first.';
  end if;
end;
$$;
revoke all on function erp_meta.add_help_actions(text, text[]) from public, anon, authenticated;

select erp_meta.add_help_actions('/procurement', array['erp_set_order_behaviour', 'erp_call_off_blanket_order', 'erp_confirm_drop_ship', 'erp_stamp_approval_routing', 'erp_blanket_position', 'erp_order_behaviours']);
select erp_meta.add_help_actions('/sales', array['erp_raise_drop_ship_order', 'erp_raise_intercompany_order', 'erp_set_line_stock_identity', 'erp_return_reasons']);
select erp_meta.add_help_actions('/planning', array['erp_run_planning', 'erp_firm_planned_order', 'erp_adjust_forecast_line', 'erp_upsert_forecast_event', 'erp_planned_order_pegging', 'erp_dependent_demand', 'erp_compare_planning_runs', 'erp_forecast_lines', 'erp_planning_runs', 'erp_forecast_events']);
select erp_meta.add_help_actions('/finance', array['erp_configure_consolidation', 'erp_post_intercompany_elimination', 'erp_set_exchange_rate', 'erp_reconcile_settlement_statement', 'erp_match_settlement_line', 'erp_apply_settlement_statement', 'erp_consolidated_trial_balance', 'erp_eliminations', 'erp_settlement_statement', 'erp_settlement_statements']);
select erp_meta.add_help_actions('/inventory', array['erp_commit_allocation', 'erp_amend_batch', 'erp_create_batch', 'erp_create_handling_unit', 'erp_set_item_controls', 'erp_set_standard_cost']);
select erp_meta.add_help_actions('/logistics', array['erp_confirm_delivery', 'erp_fail_delivery']);
select erp_meta.add_help_actions('/master-data', array['erp_create_party_with_roles', 'erp_add_party_role', 'erp_merge_master_record', 'erp_create_uom', 'erp_uoms']);
select erp_meta.add_help_actions('/administration/configuration', array['erp_submit_change_set', 'erp_rollback_to_snapshot', 'erp_upsert_reason_code', 'erp_set_reason_code_status', 'erp_reason_codes']);
select erp_meta.add_help_actions('/operations/cutover', array['erp_opening_balance_reconciliation']);
select erp_meta.add_help_actions('/operations/integrations', array['erp_reconcile_ambiguous_command', 'erp_cancel_command', 'erp_submit_command']);
select erp_meta.add_help_actions('/operations/output', array['erp_render_output_template', 'erp_route_print']);
select erp_meta.add_help_actions('/reporting/distribution', array['erp_remove_report_pack_item']);
select erp_meta.add_help_actions('/administration/organisation', array['erp_create_entity']);
select erp_meta.add_help_actions('/commercial/quotes', array['erp_quote_margin']);
select erp_meta.add_help_actions('/governance', array['erp_apply_mass_change', 'erp_reverse_mass_change']);

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The words the screens say
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, module_code) values
  ('nav.finance_dimensions', 'en', 'Analysis dimensions', 'finance'),
  ('nav.finance_dimensions', 'de', 'Analysedimensionen', 'finance')
on conflict (key, locale) do update set value = excluded.value, module_code = excluded.module_code;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). Phase 8: the screens for the doors that had none.'
  from (values
  ('1 to 12.'),
  ('2 doubles demand in the window; 0.5 halves it.'),
  ('A batch of a product, with the dates the label carries.'),
  ('A bought item becomes a purchase order of the type you name; a made item becomes a works order.'),
  ('A business partner is one record with the roles it plays. Two records for one partner are merged into a survivor, with the reason kept.'),
  ('A case, carton or pallet at a location, within the site''s identity policy.'),
  ('A change is submitted for approval by hand when its author is done; a promoted snapshot can be rolled back to, with a reason, when a promotion turns out wrong.'),
  ('A command that was sent and never answered is ambiguous until a person says what the other side did. The evidence is kept.'),
  ('A date as YYYY-MM-DD; a status as its code.'),
  ('A derivation is a JsonLogic expression over the posting''s facts — document, account, line, entity — that returns one of the dimension''s value codes. It is checked against those facts when it is saved, not discovered at month end.'),
  ('A drop-ship is bought from a supplier who delivers to the customer; an intercompany order is mirrored into the company that supplies it. Stock identity pins a line to a batch, location or handling unit.'),
  ('A further legal entity of this organisation, with its own currency, country, locales and fiscal year. Finance is installed for it separately.'),
  ('A person''s match of one line to one open receivable, with a note that says why.'),
  ('A promotion, a launch or a closure the statistics cannot know about: a window and a multiplier the next run applies.'),
  ('A purchase order to the supplier, addressed to the customer, priced from the catalogue and linked line by line to this sales order.'),
  ('A rate from one currency to another from a date, with where it came from.'),
  ('A rule has a scope (when it applies; empty is always) and a condition, both JsonLogic over account, dimensions and entity. Forbid refuses the line when the condition holds; permit refuses it when the condition does not. Evaluated for every journal, however it was raised.'),
  ('Active'),
  ('Add a company to a group'),
  ('Add a role to a business partner'),
  ('Add or amend a dimension'),
  ('Add or amend a reason code'),
  ('Add or amend a rule'),
  ('Adjust a forecast bucket'),
  ('Allocation id'),
  ('Amend'),
  ('Amend a batch'),
  ('Amend a committed line'),
  ('Analysis dimensions'),
  ('Applies an approved mass change to every record it names. Each record''s old value is kept, so the whole change can be reversed as one.'),
  ('Apply a mass change'),
  ('Apply a settlement statement'),
  ('Assumptions'),
  ('Average'),
  ('Base'),
  ('Base unit of its class'),
  ('Batch and serial control, shelf life and quarantine on receipt, for one product.'),
  ('Best before'),
  ('Blanket agreement runs to'),
  ('Blanket position'),
  ('Build a handling unit'),
  ('CC, DEPT, PROJECT.'),
  ('Call off a blanket order'),
  ('Cancel a queued command'),
  ('Carrier reference'),
  ('Carton'),
  ('Case'),
  ('Change one bucket of a draft forecast. The statistical figure stays beside it.'),
  ('Change one controlled field of a batch. The old value and the reason are kept.'),
  ('Changes and snapshots'),
  ('Closing'),
  ('Combination rules'),
  ('Comma separated. Empty removes every requirement.'),
  ('Comma separated: customer, supplier, carrier, manufacturer, broker, consignee, agent.'),
  ('Command id'),
  ('Commit an allocation'),
  ('Compare two runs'),
  ('Condition'),
  ('Confirm a delivery'),
  ('Confirm a drop-ship'),
  ('Consolidated trial balance'),
  ('Consolidates'),
  ('Consumes'),
  ('Converts'),
  ('Corrects'),
  ('Cost centres, projects and the like: their values, how a posting derives them, and which combinations are allowed.'),
  ('Country of origin'),
  ('Create a batch'),
  ('Create a business partner with roles'),
  ('Create a company'),
  ('Create a unit of measure'),
  ('Credits'),
  ('Current baseline'),
  ('Decimal places'),
  ('Decimals'),
  ('Delivered on'),
  ('Dependent demand of a run'),
  ('Derivation'),
  ('Derived'),
  ('Dimension'),
  ('Dimension codes'),
  ('Dimensions and values'),
  ('Document'),
  ('Document locale'),
  ('Dry run'),
  ('Duplicate id'),
  ('Eliminate intercompany balances'),
  ('Eliminations'),
  ('Every action taken under a support access is recorded against it, with the reason, so the customer''s continuity screen shows what was done and why.'),
  ('Every bucket of one forecast version, with the statistical figure beside any adjustment.'),
  ('Every reason code by category, and what it insists on.'),
  ('Every reference to the duplicate is moved to the survivor; the duplicate is withdrawn, not deleted.'),
  ('Every run kept: baselines, the runs they superseded, and scenarios beside them.'),
  ('Every unit a product can be counted, weighed or measured in.'),
  ('Every value, its parent and the window it is valid in.'),
  ('Evidence'),
  ('Exceptions'),
  ('Expires on'),
  ('Expiry date'),
  ('Fees'),
  ('Field'),
  ('Firm a planned order'),
  ('Fiscal year starts in month'),
  ('For a blanket order only.'),
  ('For a bought item, for example purchase_order. Leave empty for a made item.'),
  ('For a subsidiary.'),
  ('For example RETURN, WRITE_OFF, PRICE_OVERRIDE.'),
  ('For example en-GB or de.'),
  ('For one loaded batch: each check the load has to satisfy, the expected and actual figures, and whether it passes.'),
  ('Forbid when the condition holds'),
  ('Forecast events'),
  ('Forecast line id'),
  ('Forecast lines'),
  ('From currency'),
  ('From the Forecast lines question below.'),
  ('From the Settlement statement question below.'),
  ('From the change''s promotion record.'),
  ('Fulfils'),
  ('Gross'),
  ('Handling unit id'),
  ('Idempotency key'),
  ('Inactive'),
  ('Inside handling unit'),
  ('Invoices'),
  ('It changed something'),
  ('It did not arrive, and why. The reason is what the carrier review reads.'),
  ('It failed'),
  ('It succeeded'),
  ('JSON, validated against the operation''s schema.'),
  ('Kind of rate'),
  ('Kind of record'),
  ('Kind of record touched'),
  ('Left empty, the document''s own.'),
  ('Length'),
  ('Link'),
  ('Link this document to another'),
  ('Locale'),
  ('Log a support action'),
  ('Manufactured on'),
  ('Mass change id'),
  ('Master pallet'),
  ('Match a settlement line'),
  ('Matches each line to an open receivable by the invoice it names, else by an amount only one item has.'),
  ('Merge duplicate records'),
  ('Minimum remaining shelf life (days)'),
  ('Mirrors'),
  ('Mirrors this sales order as a purchase order in the buying company, at its site, in its currency.'),
  ('Multiplier'),
  ('Needs a note'),
  ('Needs approval'),
  ('New quantity'),
  ('New value'),
  ('No combination rule. Every combination of values is allowed until one is written.'),
  ('No dimension declared. Add one above; a department creates its own DEPARTMENT dimension.'),
  ('No forecast events. Record one when something the statistics cannot know is coming.'),
  ('No planning run yet. Run planning for a site and the run is kept here.'),
  ('Quote'),
  ('No reason codes yet. The base pack ships a starter set when it is applied; add one above.'),
  ('No returns in the window. Customer returns raised with a reason code are counted here.'),
  ('No settlement statement imported. Stage one on the Imports screen as a settlement_statement batch and load it.'),
  ('No unit of measure yet. The first product creates one; a further one is created above.'),
  ('No, read only'),
  ('Object id'),
  ('One of the candidates the same question lists.'),
  ('One provider statement line by line: what each line settled, how it was matched, and the candidates for a line nobody could place.'),
  ('Open Imports'),
  ('Opening balance reconciliation'),
  ('Orders'),
  ('Orders that are fulfilled elsewhere'),
  ('Pallet'),
  ('Parent company code'),
  ('Parent value code'),
  ('Partners, roles and duplicates'),
  ('Payload'),
  ('Pegged to'),
  ('Per product, what each run planned and the difference — a baseline against a scenario, or two baselines.'),
  ('Permit only when the condition holds'),
  ('Pin a line''s stock identity'),
  ('Plan one site under assumptions, beside the baseline. A scenario''s orders are never supply and cannot be firmed; compare it with the baseline instead.'),
  ('Planning runs'),
  ('Posts what the group''s companies owe each other into the group ledger as at a date. Refused while any pair disagrees.'),
  ('Preview a document''s dimensions'),
  ('Provider'),
  ('Provider statements imported, reconciled and applied, with what is still unmatched.'),
  ('Purchase order type'),
  ('Puts a subsidiary under its parent, installs the parent''s group ledger and promotes the elimination rule.'),
  ('Puts every record the mass change touched back as it was.'),
  ('Queues one operation on a connected system for the worker to deliver. A dry run is settled as simulated and sends nothing.'),
  ('Quote margin'),
  ('Raise a drop-ship order'),
  ('Raise an intercompany order'),
  ('Raises a standard purchase order against the agreement. Each line consumes a blanket line.'),
  ('Reason codes'),
  ('Receivable item id'),
  ('Reconcile a settlement statement'),
  ('Reconcile an ambiguous command'),
  ('Record a failed delivery'),
  ('Record a forecast event'),
  ('Record a support action'),
  ('Records how the two relate. The relation is what lineage and matching read.'),
  ('Related document'),
  ('Relation'),
  ('Remove a report from a pack'),
  ('Render an output template'),
  ('Renders one template for one document in a locale, into the output store.'),
  ('Reporting locale'),
  ('Require dimensions on an account'),
  ('Requires a note'),
  ('Requires approval'),
  ('Restores the configuration a promotion took a snapshot of. The reason is kept with the rollback.'),
  ('Retest date'),
  ('Return reasons'),
  ('Returns'),
  ('Reverse a mass change'),
  ('Roles'),
  ('Roll back to a snapshot'),
  ('Route a render to a printer'),
  ('Route an approval by value'),
  ('Rows are staged as they were received and validated before anything is written. Master data rows name the record by code; a settlement statement is one statement per batch, a row per payout line.'),
  ('Run a scenario'),
  ('Scenario'),
  ('Scenario code'),
  ('Scope'),
  ('Send it again'),
  ('Sends a render through the print routes for a site and workstation.'),
  ('Set a standard cost'),
  ('Set an exchange rate'),
  ('Set an order''s behaviour'),
  ('Set product controls'),
  ('Settlement statement'),
  ('Settlement statements'),
  ('Settles every matched line''s receivable as cash. Refused while a line is unmatched.'),
  ('Share %'),
  ('Shelf life (days)'),
  ('Snapshot id'),
  ('Spot'),
  ('Stage an import'),
  ('Staging a batch'),
  ('Stamp which chain a value in a currency would route to, for a department, before raising the document.'),
  ('Standard, blanket, consignment, drop-ship or intercompany. Fixed once the order is sent.'),
  ('Starts on'),
  ('Statement'),
  ('Statement line id'),
  ('Submit a change for approval'),
  ('Submit a command'),
  ('Support access id'),
  ('Survivor id'),
  ('Switch a reason code on or off'),
  ('System'),
  ('The batch, location or handling unit a sales line must be fulfilled from.'),
  ('The customer has it. Confirming is what closes the delivery and starts the clock on the invoice.'),
  ('The demand behind a planned order, and the component orders it caused: forecast, sales order or a parent order above it.'),
  ('The dimensions a line to this account must carry.'),
  ('The id of the coarser unit this one goes into, if any.'),
  ('The margin of one quote, line by line, against the cost model in force.'),
  ('The quantity changes; the old figure and the reason are kept with the line.'),
  ('The record and every role it plays, in one step.'),
  ('The reservation the sales line holds; leave location and batch empty to let the policy choose.'),
  ('The standard a product is valued at, at one site, under standard costing.'),
  ('The supplier delivered straight to the customer: both the purchase and the sales order are fulfilled, and no stock moves here.'),
  ('The windows and multipliers the forecast applies, with their reasons.'),
  ('The worksheet for a group: what the companies hold per account, what the group ledger eliminates, and the consolidated figure.'),
  ('Time'),
  ('To currency'),
  ('Turn a reservation into a pick from one location and batch, under the site''s allocation policy.'),
  ('Two-letter code.'),
  ('Unit cost'),
  ('Units of measure'),
  ('Unmatched'),
  ('Value (minor units)'),
  ('Value code'),
  ('Values of a dimension'),
  ('Volume'),
  ('Weight'),
  ('What each journal line would be stamped with when this document posts, and whether the combination rules let it through.'),
  ('What each journal line would be stamped with when this document posts, and whether the rules let it through.'),
  ('What happened'),
  ('What has been eliminated in a group ledger, when, why and by which journal.'),
  ('What the person posting is told.'),
  ('What the production orders a run raised ask of their components, by date.'),
  ('What the rows are'),
  ('What this organisation analyses postings by, and how each is derived.'),
  ('What was agreed on a blanket order, what the call-offs have consumed, and what is left, line by line.'),
  ('What was done'),
  ('What you saw on the other side.'),
  ('Where the file came from. Default manual.'),
  ('Where the relation carries one.'),
  ('Which values an account may carry together, and what the person posting is told.'),
  ('Who published it.'),
  ('Why customers have returned goods over the last ninety days, by reason code.'),
  ('Why something happened, from a list the organisation maintains: a return, a write-off, a price override. A code can insist on a note or an approval.'),
  ('Why this planned order')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.door_register_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_named text[];
  v_msg   text;
  v_ok    boolean;
  v_n     integer;
begin
  -- Every door the register does not hold, as if the application named it.
  select array_agg(m.door order by m.door) into v_named
    from erp.door_manifest() m
   where not exists (select 1 from erp_meta.api_only_door a where a.function_name = m.door);

  return query select 'every registered door exists, and every pending one names its screen',
    not exists (select 1 from erp.door_home_report() f where f.finding = 'the register names a door that does not exist')
    and not exists (select 1 from erp_meta.api_only_door a where a.caller = 'pending_screen' and a.intended_screen_path is null)
    and (select count(*) from erp_meta.api_only_door) >= 10,
    format('%s registered, %s waiting for a screen',
           (select count(*) from erp_meta.api_only_door),
           (select count(*) from erp_meta.api_only_door a where a.caller = 'pending_screen'));

  v_msg := erp.assert_doors_have_a_home(v_named);
  return query select 'with every other door named, every door has a home',
    v_msg like 'doors: % named by the application, % api-only, % waiting for a screen; every door has a home', v_msg;

  begin
    perform erp.assert_doors_have_a_home(v_named[1 : cardinality(v_named) - 1]);
    v_ok := false; v_msg := 'a door with no screen and no row passed';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_DOOR_HAS_NO_HOME: 1 door(s)%' || v_named[cardinality(v_named)] || '%'; v_msg := left(sqlerrm, 120);
  end;
  return query select 'a door that is neither named nor registered fails the build by name', v_ok, v_msg;

  begin
    perform erp.assert_doors_have_a_home(v_named || array['erp_scan']);
    v_ok := false; v_msg := 'a stale register row passed';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_API_ONLY_DOOR_IS_NAMED: 1 registered door(s)%erp_scan%'; v_msg := left(sqlerrm, 120);
  end;
  return query select 'a registered door that a screen now names is a stale row, and fails by name', v_ok, v_msg;

  begin
    insert into erp_meta.api_only_door (function_name, caller, reason)
    values ('erp_zz_never_built', 'worker', 'a row the suite plants for a door that does not exist');
    select count(*) into v_n from erp.door_home_report() f
     where f.finding = 'the register names a door that does not exist' and f.reference = 'erp_zz_never_built';
    begin
      perform erp.assert_doors_have_a_home(v_named);
      v_ok := false; v_msg := 'a row for a missing door passed';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_API_ONLY_DOOR_MISSING: 1 registered door(s)%erp_zz_never_built%'; v_msg := left(sqlerrm, 120);
    end;
    v_ok := v_ok and v_n = 1;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_ok := false; v_msg := left(sqlerrm, 200);
    end if;
  end;
  return query select 'a row for a door that does not exist is reported and refused, and rolled back',
    v_ok and not exists (select 1 from erp_meta.api_only_door a where a.function_name = 'erp_zz_never_built'),
    v_msg;

  return query select 'the help register carries the new screen and its doors, and the guidance assertion is green',
    exists (select 1 from erp_ref.help_topic h where h.screen_path = '/finance/dimensions'
             and 'erp_upsert_dimension' = any (h.actions))
    and (select count(*) from erp_ref.help_topic h where 'erp_firm_planned_order' = any (h.actions)) = 1
    and not exists (select 1 from erp.guidance_register_report())
    and exists (select 1 from erp_ref.resource r where r.key = 'nav.finance_dimensions' and r.locale = 'de'),
    '/finance/dimensions in the register; guidance sound';
end;
$$;

create or replace function erp_test.assert_door_register_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _door_register on commit drop as
    select * from erp_test.door_register_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _door_register;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_DOOR_REGISTER_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_DOOR_REGISTER_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('door register: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_door_register_suite() from public, anon, authenticated;
revoke all on function erp_test.door_register_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_door_register_suite();
select erp.assert_guidance_sound();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage('de');

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_linter_clean();

do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
