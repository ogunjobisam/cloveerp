-- =============================================================================
-- The strings Part 18's new keys resolve to
--
-- CI failed:
--
--   ERPWARE_RESOURCE_GAP: 2 key(s) with no en string
--     erp_ref.event_type: event.commercial.capability_refused
--     erp_ref.event_type: event.commercial.entitlement_exceeded
--
-- D6 — "No user-facing literal anywhere. Every string resolves through a
-- resource key with locale fallback." Part 18 declared two event types with
-- name_keys and never seeded the strings behind them, so the keys resolved to
-- nothing. The register said what the strings were called; nothing said what
-- they were.
--
-- Also seeded here: job_handler.report_entitlement_breaches.name. The resource
-- assertion does not check job handler name keys, so this was not part of the
-- failure — but eleven of the other twelve handlers have an English string, and
-- a job whose name resolves to nothing on the operations screen is the same
-- defect wearing a hat the assertion happens not to look under.
--
-- Two things this exposed about how it was missed, both worth recording:
--
--   1. erp.assert_resource_coverage() takes a DEFAULTED argument, so the local
--      sweep — which selects pronargs = 0 — never ran it. That is the same
--      filter bug found earlier against assert_determination_coverage(), noticed
--      then, and not carried into the next wave. The sweep script is corrected
--      alongside this migration.
--   2. Nothing runs at migration time to catch it either. So this migration ends
--      by calling the assertion, which is what every migration adding a key
--      should have been doing.
-- =============================================================================

insert into erp_ref.resource (key, locale, value, description) values
('event.commercial.entitlement_exceeded', 'en',
 'Plan limit exceeded',
 'Raised when an organisation is over one of the limits its plan sets. §18.1 requires a notification as well as a refusal.'),
-- "Feature", not "capability". erp_ref.vocabulary marks capability as internal
-- surface with the product term Feature, and erp.assert_vocabulary_aligned()
-- refuses model vocabulary in a user-facing string — which it did, on the first
-- run of the corrected sweep. Every existing screen string already says Feature;
-- this one now agrees with them.
('event.commercial.capability_refused', 'en',
 'Feature not available on this plan',
 'Raised when a feature was requested that the organisation''s plan does not carry.'),
('job_handler.report_entitlement_breaches.name', 'en',
 'Report plan-limit breaches',
 'The scheduled sweep behind §18.1''s notification. Named here because a job whose name does not resolve is a blank row on the operations screen.')
on conflict (key, locale) do update set
  value = excluded.value, description = excluded.description;

-- The assertion that failed, run here so this migration cannot land without it
-- passing. Called with the argument it defaults to, because the defaulted form
-- is precisely the one a pronargs = 0 sweep does not reach.
select erp.assert_resource_coverage('en');

-- And the terminology guard, which is what caught 'capability' in the string
-- above. A key that resolves to model vocabulary is a key that resolves.
select erp.assert_vocabulary_aligned();
