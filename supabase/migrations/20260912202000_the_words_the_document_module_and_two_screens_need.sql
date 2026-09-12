-- Four keys with no string, and two screens whose names do not exist.
--
-- The document module, its three permissions and the two finance screens were
-- all registered without the words that render them. On the first build to
-- reach the check catalogue this came back four ways:
--
--   erp.assert_resource_coverage     4 key(s) with no en string
--   erp.assert_resource_coverage_de  4 key(s) with no de string
--   erp.assert_guidance_sound        help topic names a navigation key with no
--                                    base-locale resource — nav.finance_cost_centres,
--                                    nav.finance_statements
--
-- A permission with no string is a checkbox on the roles screen with a key
-- where its name should be, and a nav key with no string is a menu item that
-- reads "nav.finance_statements". Neither would have survived being looked at
-- once; neither had been.
--
-- German because the coverage gate is run in both locales and has been since
-- 20260906082000: a locale that is asserted is a locale that is maintained.

insert into erp_ref.resource (key, locale, value, module_code) values
  ('nav.finance_statements',    'en', 'Profit and balance sheet', 'finance'),
  ('nav.finance_statements',    'de', 'Bilanz und GuV',           'finance'),
  ('nav.finance_cost_centres',  'en', 'Cost centres',             'finance'),
  ('nav.finance_cost_centres',  'de', 'Kostenstellen',            'finance')
on conflict (key, locale) do update
  set value = excluded.value, module_code = excluded.module_code;

insert into erp_ref.resource (key, locale, value, description) values
  ('module.document', 'en', 'Document output', 'Module title'),
  ('permission.document.issue',           'en', 'Issue documents',           ''),
  ('permission.document.reprint',         'en', 'Reprint issued documents',  ''),
  ('permission.document.template_manage', 'en', 'Manage document templates', '')
on conflict (key, locale) do update
  set value = excluded.value, description = excluded.description;

insert into erp_ref.resource (key, locale, value) values
  ('module.document', 'de', 'Belegausgabe'),
  ('permission.document.issue',           'de', 'Belege ausgeben'),
  ('permission.document.reprint',         'de', 'Belege erneut ausgeben'),
  ('permission.document.template_manage', 'de', 'Belegvorlagen verwalten')
on conflict (key, locale) do update set value = excluded.value;

select erp.assert_resource_coverage();
select erp.assert_resource_coverage_de();
select erp.assert_guidance_sound();
