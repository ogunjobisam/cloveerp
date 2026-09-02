-- ─────────────────────────────────────────────────────────────────────────────
-- The strings the screen search is made of.
--
-- 20260904690000 moved the navigation onto the words erp_ref.vocabulary
-- already preferred — Stock, Purchasing, Common data, Despatch. Renaming a
-- menu is only half of that decision. The other half is that somebody who
-- learned "inventory", "item" or "vendor" somewhere else must still be able
-- to find the screen, or the rename has traded one group's confusion for
-- another's.
--
-- The command palette is where that is paid for. It searches the screens by
-- title, and erp_ref.vocabulary by term, definition and alias, so "inventory"
-- offers Stock and says so: "Also known as Inventory", rather than silently
-- correcting the word. A search that quietly rewrites what you typed teaches
-- nothing; one that names the substitution teaches it once.
--
-- Its own chrome is seeded here because supabase/ci/screen_strings.sh requires
-- it and is right to: a string with no row cannot be renamed by an
-- organisation, and this product's claim is that every visible word can be.
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text, 'Screen search (command palette).'
  from (values
    ('Search'),
    ('Search screens'),
    ('Go to a screen, or type what you call it'),
    ('Also known as'),
    ('Nothing matches that. Try the word another system would use for it.')
  ) as v(text)
on conflict (key, locale) do update set
  value = excluded.value, description = excluded.description;

select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
