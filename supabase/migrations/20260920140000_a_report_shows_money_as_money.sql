set lock_timeout = '30s';

-- =============================================================================
-- 20260920140000  A report shows money as money
-- -----------------------------------------------------------------------------
-- The Stock Reports tab's Valuation report had a column headed "VALUE (MINOR)"
-- holding 125000, 58800 and 8000 — £1,250.00, £588.00 and £80.00 — beside a
-- tile on the same screen that correctly said £1,918. A person reads 125000 as
-- one hundred and twenty-five thousand pounds.
--
-- The screen now formats it, and its description stops promising minor units:
-- "Cost basis by product and site, in minor units." becomes "Cost basis by
-- product and site." That is a new sentence on a screen, and every sentence a
-- screen passes through ui() has a row an organisation can rename it by, or
-- supabase/ci/screen_strings.sh refuses the build. This is that row, and
-- nothing else.
--
-- Minor units are unchanged everywhere they belong: in the door, in the API and
-- in anything exported from them.
-- =============================================================================

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string on Stock, rendered through ui(). ' || v.why
  from (values
    ('Cost basis by product and site.',
     'Under the Valuation report. It used to add "in minor units", which was true of a column that printed 125000 for £1,250.00 and is not true of one that prints £1,250.00.')
  ) as v(text, why)
on conflict (key, locale) do nothing;

select erp.assert_resource_coverage('en');
