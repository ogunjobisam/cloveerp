-- =============================================================================
-- The wording of the features and content screen
--
-- supabase/ci/screen_strings.sh refused the build over 32 of these, which is
-- exactly what it was written for: every literal a screen passes through ui()
-- needs a row, or no organisation can rename it. The screen was built, the
-- check named the 32, and here they are.
--
-- Two of them are worth a second look. "Features" is the word Terminology §4
-- prescribes for what the model calls a capability — the register carries that
-- mapping, and this is the first screen to use it. And "Readiness" heads §13's
-- seven clauses, which are a measurement rather than a status, so the wording
-- says what it is rather than borrowing the language of a health check.
--
-- A third was caught rather than chosen. The button read "Build the change
-- set", and erp.assert_vocabulary_aligned() refused this migration: change set
-- is on §4's never-on-a-screen list, which says to say change or release. It
-- reads "Prepare the change" now — the first time that rule has been enforced
-- against a screen being written rather than one already written.
-- =============================================================================

insert into erp_ref.resource (key, locale, value, description) values
  ('nav.administration_packs', 'en', 'Features and content',
   'Starter Content Packs §2 and §10.'),
  ('module.packs', 'en', 'Features and content',
   'Starter Content Packs §2 and §10.')
on conflict (key, locale) do update set
  value = excluded.value, description = excluded.description;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(t.text), 'en', t.text,
       'Screen wording on features and content, keyed by its own source text.'
  from (values
    ('Answer'),
    ('Apply'),
    ('Prepare the change'),
    ('Building…'),
    ('Change'),
    ('Close'),
    ('Content packs'),
    ('Effect'),
    ('Features'),
    ('Held back'),
    ('History'),
    ('Kind'),
    ('Less'),
    ('Needed by'),
    ('Needs'),
    ('Never switched.'),
    ('No features in the catalogue.'),
    ('No packs are published.'),
    ('Nothing depends on it.'),
    ('Nothing.'),
    ('Object'),
    ('Plan'),
    ('Presets'),
    ('Readiness'),
    ('Reason (recorded with the switch)'),
    ('Switch off'),
    ('Switch on'),
    ('This pack cannot be applied as it stands'),
    ('Working…'),
    ('held'),
    ('holds'),
    ('not applied'),
    ('off'),
    ('on'),
    ('open'),
    ('short')
  ) t(text)
on conflict (key, locale) do nothing;

-- en-US, for the two that differ. "Features" and the rest read the same on
-- both sides of the Atlantic; these do not.
insert into erp_ref.resource (key, locale, value, description) values
  (erp_ref.ui_key('Content packs'), 'en-US', 'Content packs', null)
on conflict (key, locale) do update set value = excluded.value;

select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
