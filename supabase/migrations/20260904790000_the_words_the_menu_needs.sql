-- ─────────────────────────────────────────────────────────────────────────────
-- The words the whole-product menu needs.
--
-- src/components/erp/menu.tsx puts every screen on one page — an area column
-- beside a grouped tree, searched across both areas at once — which is the
-- navigation device this product had been missing between the rail (where am
-- I) and the palette (take me somewhere I can name). Six words come with it,
-- and like every other visible word they belong in erp_ref.resource so an
-- organisation can rename them.
--
-- "Menu" and "Areas" look too small to be worth a row until a deployment runs
-- in French, at which point they are the two words framing everything else.
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'Screen string declared in src/lib/modules.tsx or written as a ui() literal.'
  from (values
    ('Areas'),
    ('Collapse all'),
    ('Expand all'),
    ('Menu'),
    ('Nothing here matches that. Try the word another system would use.'),
    ('Search the menu')
  ) as v(text)
on conflict (key, locale) do nothing;

select erp.assert_resource_coverage('en');
