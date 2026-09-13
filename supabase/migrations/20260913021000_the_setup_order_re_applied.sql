-- The setup order, re-applied.
--
-- 20260913020000 was edited after it was pushed. Its first version gave the
-- audit screen a blurb of nineteen characters against the register's own
-- check of twenty, so the file refused at that statement on every environment
-- that tried it — the build's empty cluster and the preview branch alike —
-- and applied nowhere. The second version fixed the one word; the third took
-- out three refusal registrations for codes erp.refusal_report() does not read,
-- which its own assertion refused at the file's last line. Each is an edit to
-- a pushed migration, and the rule does not ask whether the first
-- version reached anywhere: it asks for a new migration that re-applies the
-- definition, and a line in supabase/ci/migrations_edited.txt naming it. This
-- is that migration. It re-applies the setup order exactly as the edited file
-- states it, so an environment that had somehow kept the first version would
-- hold the same rows as one that had not.

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

select erp.assert_setup_walkthrough_actionable();
