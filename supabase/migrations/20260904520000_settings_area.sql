-- =============================================================================
-- The Settings area.
--
-- The interface now has two areas: Work, which is the operating flow and its
-- records, and Settings, which is everything that shapes the organisation
-- rather than runs it — who is in it, how it is configured, the plumbing
-- underneath, and the assurance over all of it. Nothing moved in the
-- database; the same doors serve the same screens. What the database carries
-- for the interface is its wording and its guidance, and both need rows for
-- the new area: the navigation keys the shell reads, the group labels a tenant
-- may rename, and a help topic for the area's home, because every screen with
-- a help button has one and the build checks it.
-- =============================================================================

insert into erp_ref.resource (key, locale, value, description) values
('nav.settings', 'en', 'Settings',
 'The area that holds administration and configuration, separate from the work. Its home is /settings.'),
('nav.work', 'en', 'Work',
 'The area that holds the operating flow and its records. Its home is /.')
on conflict (key, locale) do update set
  value = excluded.value, description = excluded.description;

-- The group labels and the launchpad wording, keyed by their own source text
-- so a tenant can rename them from the terminology screen.
insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(t.text), 'en', t.text,
       'Screen wording, keyed by its own source text so a tenant can rename it.'
  from (values
    ('Records'),
    ('Organisation'),
    ('Configure'),
    ('Operate'),
    ('Assure'),
    ('Settings'),
    ('Welcome'),
    ('there'),
    ('All companies'),
    ('All sites'),
    ('The flow'),
    ('Plan, source, make, move, sell, settle. Each stage lists only the screens this account may open.'),
    ('Organisation, configuration, operations and assurance live in their own area, out of the way of the work.'),
    ('Some sections are not shown because this account does not hold the permissions they require.'),
    ('How this organisation is set up, in the order it is set up: the people and their permissions, the configuration the modules run on, the plumbing underneath, and the evidence that all of it holds.'),
    ('Explore with demo data'),
    ('Creates a demo organisation with companies, sites and a viewer, and switches your working context to it. Your current organisation is untouched.'),
    ('Decide what should happen and when.'),
    ('Bring materials and services in.'),
    ('Turn inputs into finished goods, and check them.'),
    ('Hold, count and ship what exists.'),
    ('Quote, order and deliver to customers.'),
    ('Value it, invoice it, close the period.'),
    ('The master data everything depends on, how it changes, and the reports over it.'),
    ('Who is in the organisation, what they may do, and the plan it is on.'),
    ('How the modules behave: installed configuration, packs, codes, terminology.'),
    ('The plumbing: jobs, integrations, printing, devices, continuity, cutover.'),
    ('The evidence: the audit log, the assertions, personal data, accessibility, adoption.')
  ) t(text)
on conflict (key, locale) do update set
  value = excluded.value, description = excluded.description;

-- The tile blurbs pass through ui() now as well, so each needs its row.
insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(t.text), 'en', t.text,
       'A launchpad tile''s one-line description, keyed by its own source text so a tenant can rename it.'
  from (values
    ('Quotations, orders and deliveries.'),
    ('Requisitions, purchase orders and goods receipts.'),
    ('The items and parties every document depends on.'),
    ('Proposed master data changes and the approvals on them.'),
    ('Staged batches, preview, validation, load and rollback.'),
    ('Every report version, the governed view it reads, and each run with the parameters it used — so what was shown can be shown again.'),
    ('What is running, what failed, and what has stopped running.'),
    ('Outbound gateway health and the queue that needs a decision.')
  ) t(text)
on conflict (key, locale) do nothing;

-- Help for the area's home, and the Work home's guidance updated to say
-- where the settings went.
insert into erp_ref.help_topic (screen_path, nav_key, module_code, summary, steps, next_action, actions) values
  ('/settings', 'nav.settings', 'administration',
   'Everything that shapes the organisation rather than runs it, in four sections: Organisation (who is in it and what they may do), Configure (how the modules behave), Operate (the plumbing) and Assure (the evidence).',
   '["Set the organisation up top to bottom: invite people and grant roles, then install and promote configuration, then check the plumbing.","Each section lists only the screens this account may open.","Switch back to Work from the header; the day''s screens are there."]',
   'Start with People and invitations if the organisation is new.',
   '{}')
on conflict (screen_path) do update set
  nav_key = excluded.nav_key, module_code = excluded.module_code, summary = excluded.summary,
  steps = excluded.steps, next_action = excluded.next_action, actions = excluded.actions;

update erp_ref.help_topic set
  summary = 'Where you are, your first steps, and every screen this account can open, arranged the way the work runs: plan, source, make, move, sell, settle, then the records it runs on. Administration and configuration are in Settings, a separate area reached from the header.',
  steps = '["Check the company and site you are working in, in the header; narrowing them changes what is shown, not what is permitted.","Open a screen from the flow or the rail.","If you are new, follow your first-run guidance below the welcome.","Setting the organisation up, rather than working in it, happens under Settings."]'
where screen_path = '/';

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
select erp.assert_no_dead_configuration();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_guidance_sound();
