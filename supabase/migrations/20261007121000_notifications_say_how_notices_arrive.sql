set lock_timeout = '30s';

-- =============================================================================
-- 20261007121000  Notifications say how notices arrive
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-162, J-163). On
-- Notifications, the Delivery, last seven days panel described print queues
-- ("Queue depth, the oldest waiting print and the last confirmed one per
-- printer"), copied from Output and printing. Its Routes panel, empty, said
-- "No route is defined, so no event reaches anybody", although the product's
-- own routes (approvals, configuration changes to approve, failed jobs,
-- support access) reach people whenever an organisation has none of its own,
-- and notices such as a receipt that differs from its shipping notice are
-- sent directly. Its Configured channels panel, empty, said only in-app
-- delivery works, although email is sent with no channel configured: only a
-- webhook needs one. Both said "Define one under Actions above", and the
-- screen has no Actions heading: its cards are Notification routes and
-- Channels. Three more screens send people to an "Actions" heading they do
-- not draw: Subscriptions, packs and extracts; Classification and coding;
-- and Personal data and erasure.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The words those panels now say, each naming the card above it by its
--      heading. Personal data and erasure's empty sentence is written into
--      its screen and needs no row.
--
-- Output and printing, Organisation and approval routing, and Loading bays
-- and waves keep "under Actions above": their actions are behind the button
-- called Actions in the page header. src/lib/empty-states.test.ts now holds
-- every "under ... above" to a heading its screen draws, and
-- src/lib/screen-duplication.test.ts holds a panel's description to one
-- screen.
--
-- On production: words are added. No routine or table is changed and no row
-- but these is written.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Notifications say how notices arrive, and empty panels name the card '
       'above them (20261007121000).'
  from (values
    ('Each channel''s messages over the last seven days, counted by where they have got to, with how long the oldest waiting one has waited.'),
    ('No route of your own is defined. The product''s own notices still arrive: approvals, configuration changes to approve, failed jobs and support access. Define a route under Notification routes above.'),
    ('No channel is configured. In-app always works and email is sent without one; a webhook needs a channel. Add one under Channels above.'),
    ('Nobody is subscribed to a report. Subscribe to one under Subscriptions, packs and the analytics contract above and it is produced on a cadence and delivered.'),
    ('No pack is defined. Define one under Subscriptions, packs and the analytics contract above, then add reports to it.'),
    ('No axes yet. Define one under Axes and values above; until one exists, products carry no structured meaning.'),
    ('No values yet. A value belongs to an axis, so define an axis first and add its values under Axes and values above.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_personal_data_register_sound();
