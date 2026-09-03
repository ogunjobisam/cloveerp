-- ─────────────────────────────────────────────────────────────────────────────
-- The words the site and location screens brought with them.
--
-- supabase/ci/screen_strings.sh holds one rule: a word on a screen with no
-- erp_ref.resource row cannot be renamed by an organisation, and this product's
-- claim is that every visible word can be. Eleven strings fail it:
--
--   Sites · Locations · Entity · Pickable · blocked · yes · no
--   GBP — pound sterling · EUR — euro · USD — US dollar
--   The books this organisation keeps.
--
-- Ten arrived with 20260903014640 and 20260903020414 — the Sites and Locations
-- panels, their column headers, the yes/no a boolean column renders, and the
-- currency labels beside them. The eleventh is this branch's: a ledger blurb
-- that said "this tenant" and now says "this organisation", which retires the
-- row the old wording had.
--
-- Seeded here rather than the check being relaxed. `yes`, `no` and `blocked`
-- look too small to bother with, and they are exactly the words a French or
-- German deployment needs first.
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'Screen string declared in src/lib/modules.tsx or written as a ui() literal.'
  from (values
    ('EUR — euro'),
    ('Entity'),
    ('GBP — pound sterling'),
    ('Locations'),
    ('Pickable'),
    ('Sites'),
    ('The books this organisation keeps.'),
    ('USD — US dollar'),
    ('blocked'),
    ('no'),
    ('yes')
  ) as v(text)
on conflict (key, locale) do nothing;

select erp.assert_resource_coverage('en');
