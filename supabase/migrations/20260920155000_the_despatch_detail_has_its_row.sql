set lock_timeout = '30s';

-- =============================================================================
-- 20260920155000  The despatch detail has its row
-- -----------------------------------------------------------------------------
-- 20260920150000 seeded a row for every sentence the plain-English pass put on a
-- screen, and missed one. Despatch's "How this works" is declared as data —
-- howItWorks on the module — and the list of new sentences was harvested with a
-- copy of supabase/ci/screen_strings.sh taken before that script was taught to
-- read the howItWorks key. The build's own copy had been taught, found the
-- sentence, and refused it: 1 of 2480 with no row.
--
-- The row, and nothing else.
-- =============================================================================

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'Despatch, behind "How this works": what used to follow the screen''s one sentence.'
  from (values
    ('The carrier''s cost is added to the value of the stock it carried.')
  ) as v(text)
on conflict (key, locale) do nothing;

select erp.assert_resource_coverage('en');
