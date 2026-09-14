-- =============================================================================
-- The tax report says what it reads
--
-- Finance's Tax report panel called erp_tax_report with neither of its dates
-- and read net_minor, which the report does not answer, so it never showed a
-- row. The panel now asks for the calendar quarter so far and shows what the
-- report returns: jurisdiction, code, rate, taxable amount, tax and how many
-- transactions. Five of its words are new to the screens, and a word on a
-- screen is one an organisation can rename, so each gets its row.
-- =============================================================================

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('Taxable amount and tax by code, for this calendar quarter so far.',
     'What Finance''s Tax report panel shows, and for which period.'),
    ('No taxable transactions this quarter. A document that carries tax appears here once it is posted.',
     'The Tax report panel when nothing posted this quarter carried tax.'),
    ('Jurisdiction',
     'The Tax report column naming the tax authority a code belongs to.'),
    ('Taxable',
     'The Tax report column with the amount tax was charged on.'),
    ('Transactions',
     'The Tax report column counting the determinations behind a row.')
) as v(text, why)
on conflict (key, locale) do nothing;

-- A row that did not land is a string the terminology screen cannot offer.
do $words$
declare v_missing text;
begin
  select string_agg(quote_literal(t.text), ', ' order by t.text) into v_missing
    from (values
      ('Taxable amount and tax by code, for this calendar quarter so far.'),
      ('No taxable transactions this quarter. A document that carries tax appears here once it is posted.'),
      ('Jurisdiction'),
      ('Taxable'),
      ('Transactions')
    ) as t(text)
   where not exists (select 1 from erp_ref.resource r
                      where r.key = erp_ref.ui_key(t.text) and r.locale = 'en');
  if v_missing is not null then
    raise exception 'CLOVEERP_SCREEN_WORDS_MISSING: % have no en row', v_missing;
  end if;
end
$words$;

select erp.assert_resource_coverage('en');
