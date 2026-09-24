set lock_timeout = '30s';

-- =============================================================================
-- 20260924300000  The words a comment hid can be renamed
-- -----------------------------------------------------------------------------
-- supabase/ci/screen_strings.sh read an apostrophe in a comment — "the
-- organisation's first" — as the opening of a string, so its scan of the tag
-- around that comment never found the tag's end and harvested nothing from it.
-- Eight files had such a comment inside an ActionBar, an ActionDialog, an
-- AutoPanel or an action's object, and 56 screen strings in them went
-- unchecked. The script now skips comments. 46 of the 56 already had the row
-- they are renamed by, seeded by the migration that put them on screen; these
-- are the ten that had none, so no organisation could rename them.
--
-- The rows, and the generators every migration ends with.
-- =============================================================================

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text, 'A screen string, rendered through ui(). ' || v.why
  from (values
    ('Sites — the places this organisation works from. Stock, receipts and despatches all happen at one.',
     'Organisation: said under the Sites card, which comes before departments because nothing that moves goods can be raised until a site exists.'),
    ('Add a site',
     'Organisation: the Sites card''s one action.'),
    ('Kind of site',
     'Organisation, adding a site: a warehouse, a production plant, a distribution centre and so on.'),
    ('A short code of your own choosing — for example GOODS-IN-BASICS. Picking one of the organisation''s own replaces it; picking a product scenario''s code starts the organisation''s own version beside it.',
     'Adoption, adding a scenario: under the code, because the same code both names a new scenario and replaces an existing one.'),
    ('One row per axis: the axis and the value chosen for it. The value must belong to the axis on the same row.',
     'Classification, creating a classified product: under the rows that answer each axis.'),
    ('Only when the object is a product.',
     'Governance, opening a change request: under the product picker, which is read only when the request is about a product.'),
    ('Only when the object is a business partner.',
     'Governance, opening a change request: under the business partner picker, which is read only when the request is about one.'),
    ('Partner, dates and every line on one form. It is saved as a whole: if a line is wrong, nothing is created.',
     'Every new document form: said under its title, because a document is created whole or not at all.'),
    ('Their own order or invoice number, so both sides can find it.',
     'Every new document form: under Their reference.'),
    ('Everything this document is for. A line left without a price takes the agreed price for that partner and product, where there is one.',
     'Every new document form: under its lines.')
  ) as v(text, why)
on conflict (key, locale) do nothing;

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
