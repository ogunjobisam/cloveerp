-- ─────────────────────────────────────────────────────────────────────────────
-- The first-run panel's own chrome, given rows it can be renamed by.
--
-- 20260904650000 rewrote the panel on Home and introduced twelve new ui()
-- literals without seeding any of them. supabase/ci/screen_strings.sh failed
-- the build for it, correctly: the terminology layer's premise is that
-- renaming is a glossary change with no code impact, and that is only true of
-- strings erp_ref.resource holds. A literal with no row is a string no
-- organisation can rename and that erp.terminology_alignment_report() cannot
-- even see to report drift on.
--
-- That migration is on main and is written once, so the rows arrive here.
--
-- Two of the twelve are gone rather than seeded. The first draft wrote
-- "N more steps" and "M already done" — the count in code, the words in the
-- resource layer. That hands a translator half a sentence and no way to put
-- the number anywhere else, which several languages need. The phrases are
-- whole now, with the count rendered beside them rather than inside them, and
-- the panel's "4 of 30" is a plain "4/30": two numerals need no glossary.
--
-- The long description is seeded although the CI grep cannot see it — it is
-- written across several lines in the source, and the grep matches a single
-- line. Whether a string can be renamed should not depend on how the
-- formatter wrapped it.
--
-- Keyed through erp_ref.ui_key() so the key matches exactly what the front end
-- computes from the same text; the two implementations agree by construction
-- rather than by a literal copied into both.
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text, 'First-run guidance panel on Home (§22.2).'
  from (values
    ('Your first steps'),
    ('First steps completed'),
    ('First-run guidance did not load.'),
    ('Show the other steps'),
    ('Hide the other steps'),
    ('Mark done'),
    ('Not for us'),
    ('Bring this back'),
    ('Set aside as not applying here.'),
    ('Nothing records that somebody read a screen, so this one is yours to tick.'),
    ('Only the steps your permissions make yours. Most tick themselves as you work — the platform reads its own records rather than asking you to remember.')
  ) as v(text)
on conflict (key, locale) do update set
  value = excluded.value, description = excluded.description;

select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_first_run_guidance_actionable();
