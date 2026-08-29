-- =============================================================================
-- ERPWare — B5: product content seed
--
-- Everything in this migration is PRODUCT content: identical for every tenant,
-- shipped with the release, and derived from standards or common practice.
-- Spec 2.3 is explicit about the line this must not cross:
--
--   "Starter templates are neutral by construction: [...] generic,
--    illustrative, derived from standards or common practice, never from a
--    customer's configuration"
--   "No customer-derived artefact may be promoted into product content."
--
-- So: currencies and countries are ISO. Locales are ISO. The permission
-- catalogue is derived from the module boundary in Part 5 of the specification.
-- The legislation pack is explicitly illustrative, uses the ISO user-assigned
-- jurisdiction code XX, and its rates are invented — it exists so the
-- conformance harness has something real to run and so onboarding has a pack to
-- select. It is not, and must never become, any jurisdiction's actual law.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Locales (ISO 639-1 / 3166-1), with fallback parents
-- -----------------------------------------------------------------------------

insert into erp_ref.locale (code, name, parent_locale, text_direction) values
  ('en',    'English',              null, 'ltr'),
  ('fr',    'Français',             null, 'ltr'),
  ('de',    'Deutsch',              null, 'ltr'),
  ('es',    'Español',              null, 'ltr'),
  ('nl',    'Nederlands',           null, 'ltr'),
  ('ar',    'العربية',               null, 'rtl')
on conflict (code) do nothing;

insert into erp_ref.locale (code, name, parent_locale) values
  ('en-GB', 'English (United Kingdom)', 'en'),
  ('en-US', 'English (United States)',  'en'),
  ('en-IE', 'English (Ireland)',        'en'),
  ('fr-CA', 'Français (Canada)',        'fr'),
  ('fr-BE', 'Français (Belgique)',      'fr'),
  ('de-AT', 'Deutsch (Österreich)',     'de'),
  ('de-CH', 'Deutsch (Schweiz)',        'de'),
  ('nl-BE', 'Nederlands (België)',      'nl')
on conflict (code) do nothing;

-- -----------------------------------------------------------------------------
-- Currencies and countries (ISO 4217, ISO 3166-1)
--
-- Note the minor units: money is stored as an integer count of these, so a
-- currency with the wrong scale silently misprices everything denominated in
-- it. JPY and KRW have none; most have two.
-- -----------------------------------------------------------------------------

insert into erp_ref.currency (code, name, minor_units) values
  ('GBP','Pound sterling',2), ('EUR','Euro',2), ('USD','US dollar',2),
  ('CHF','Swiss franc',2),    ('SEK','Swedish krona',2), ('NOK','Norwegian krone',2),
  ('DKK','Danish krone',2),   ('PLN','Polish złoty',2),  ('CZK','Czech koruna',2),
  ('CAD','Canadian dollar',2),('AUD','Australian dollar',2),
  ('NZD','New Zealand dollar',2), ('ZAR','South African rand',2),
  ('NGN','Nigerian naira',2), ('KES','Kenyan shilling',2),
  ('INR','Indian rupee',2),   ('CNY','Chinese yuan',2),
  ('SGD','Singapore dollar',2), ('HKD','Hong Kong dollar',2),
  ('AED','UAE dirham',2),     ('SAR','Saudi riyal',2),
  ('BRL','Brazilian real',2), ('MXN','Mexican peso',2),
  ('JPY','Japanese yen',0),   ('KRW','South Korean won',0)
on conflict (code) do nothing;

insert into erp_ref.country (code, name, default_currency) values
  ('GB','United Kingdom','GBP'), ('IE','Ireland','EUR'), ('FR','France','EUR'),
  ('DE','Germany','EUR'),        ('NL','Netherlands','EUR'), ('BE','Belgium','EUR'),
  ('ES','Spain','EUR'),          ('IT','Italy','EUR'),    ('PT','Portugal','EUR'),
  ('AT','Austria','EUR'),        ('PL','Poland','PLN'),   ('CZ','Czechia','CZK'),
  ('SE','Sweden','SEK'),         ('NO','Norway','NOK'),   ('DK','Denmark','DKK'),
  ('CH','Switzerland','CHF'),    ('US','United States','USD'), ('CA','Canada','CAD'),
  ('AU','Australia','AUD'),      ('NZ','New Zealand','NZD'),
  ('ZA','South Africa','ZAR'),   ('NG','Nigeria','NGN'),  ('KE','Kenya','KES'),
  ('IN','India','INR'),          ('CN','China','CNY'),    ('SG','Singapore','SGD'),
  ('HK','Hong Kong','HKD'),      ('AE','United Arab Emirates','AED'),
  ('SA','Saudi Arabia','SAR'),   ('BR','Brazil','BRL'),   ('MX','Mexico','MXN'),
  ('JP','Japan','JPY'),          ('KR','South Korea','KRW')
on conflict (code) do nothing;

-- -----------------------------------------------------------------------------
-- Modules — the boundary drawn in Part 5 of the specification
-- -----------------------------------------------------------------------------

insert into erp_ref.module (code, name_key, sort_order) values
  ('master_data',   'module.master_data',   10),
  ('inventory',     'module.inventory',     20),
  ('procurement',   'module.procurement',   30),
  ('planning',      'module.planning',      40),
  ('production',    'module.production',    50),
  ('sales',         'module.sales',         60),
  ('finance',       'module.finance',       70),
  ('quality',       'module.quality',       80),
  ('logistics',     'module.logistics',     90),
  ('reporting',     'module.reporting',    100),
  ('administration','module.administration',110)
on conflict (code) do nothing;

-- -----------------------------------------------------------------------------
-- The permission catalogue
--
-- module.action, at the granularity the specification asks for. data_class_aware
-- marks the permissions that can be further narrowed — costs and margins are the
-- obvious ones, since "can see the order" and "can see what we paid for it" are
-- routinely different answers.
-- -----------------------------------------------------------------------------

insert into erp_ref.permission (code, module_code, action, name_key, data_class_aware, is_mutating) values
  ('master_data.read',      'master_data','read',   'permission.master_data.read',   true,  false),
  ('master_data.write',     'master_data','write',  'permission.master_data.write',  true,  true),
  ('master_data.approve',   'master_data','approve','permission.master_data.approve',false, true),
  ('master_data.import',    'master_data','import', 'permission.master_data.import', false, true),

  ('inventory.read',        'inventory','read',     'permission.inventory.read',     true,  false),
  ('inventory.move',        'inventory','move',     'permission.inventory.move',     false, true),
  ('inventory.adjust',      'inventory','adjust',   'permission.inventory.adjust',   false, true),
  ('inventory.count',       'inventory','count',    'permission.inventory.count',    false, true),
  ('inventory.write_off',   'inventory','write_off','permission.inventory.write_off',false, true),

  ('procurement.read',      'procurement','read',   'permission.procurement.read',   true,  false),
  ('procurement.requisition','procurement','requisition','permission.procurement.requisition',false,true),
  ('procurement.order',     'procurement','order',  'permission.procurement.order',  false, true),
  ('procurement.approve',   'procurement','approve','permission.procurement.approve',false, true),
  ('procurement.receive',   'procurement','receive','permission.procurement.receive',false, true),
  ('procurement.match',     'procurement','match',  'permission.procurement.match',  false, true),

  ('planning.read',         'planning','read',      'permission.planning.read',      false, false),
  ('planning.forecast',     'planning','forecast',  'permission.planning.forecast',  false, true),
  ('planning.run',          'planning','run',       'permission.planning.run',       false, true),
  ('planning.firm',         'planning','firm',      'permission.planning.firm',      false, true),

  ('production.read',       'production','read',    'permission.production.read',    false, false),
  ('production.order',      'production','order',   'permission.production.order',   false, true),
  ('production.execute',    'production','execute', 'permission.production.execute', false, true),
  ('production.release',    'production','release', 'permission.production.release', false, true),

  ('sales.read',            'sales','read',         'permission.sales.read',         true,  false),
  ('sales.order',           'sales','order',        'permission.sales.order',        false, true),
  ('sales.price',           'sales','price',        'permission.sales.price',        true,  true),
  ('sales.discount_approve','sales','discount_approve','permission.sales.discount_approve',false,true),
  ('sales.credit_release',  'sales','credit_release','permission.sales.credit_release',false,true),
  ('sales.despatch',        'sales','despatch',     'permission.sales.despatch',     false, true),
  ('sales.invoice',         'sales','invoice',      'permission.sales.invoice',      false, true),

  ('finance.read',          'finance','read',       'permission.finance.read',       true,  false),
  ('finance.post',          'finance','post',       'permission.finance.post',       false, true),
  ('finance.approve_payment','finance','approve_payment','permission.finance.approve_payment',false,true),
  ('finance.close_period',  'finance','close_period','permission.finance.close_period',false,true),
  ('finance.reopen_period', 'finance','reopen_period','permission.finance.reopen_period',false,true),
  ('finance.configure',     'finance','configure',  'permission.finance.configure',  false, true),

  ('quality.read',          'quality','read',       'permission.quality.read',       false, false),
  ('quality.inspect',       'quality','inspect',    'permission.quality.inspect',    false, true),
  ('quality.disposition',   'quality','disposition','permission.quality.disposition',false, true),
  ('quality.release_batch', 'quality','release_batch','permission.quality.release_batch',false,true),
  ('quality.recall',        'quality','recall',     'permission.quality.recall',     false, true),

  ('logistics.read',        'logistics','read',     'permission.logistics.read',     false, false),
  ('logistics.plan',        'logistics','plan',     'permission.logistics.plan',     false, true),
  ('logistics.despatch',    'logistics','despatch', 'permission.logistics.despatch', false, true),

  ('reporting.read',        'reporting','read',     'permission.reporting.read',     true,  false),
  ('reporting.define',      'reporting','define',   'permission.reporting.define',   false, true),
  ('reporting.export',      'reporting','export',   'permission.reporting.export',   true,  true),

  ('administration.read',   'administration','read','permission.administration.read',false, false),
  ('administration.users',  'administration','users','permission.administration.users',false,true),
  ('administration.roles',  'administration','roles','permission.administration.roles',false,true),
  ('administration.configure','administration','configure','permission.administration.configure',false,true),
  ('administration.promote','administration','promote','permission.administration.promote',false,true),
  ('administration.integrate','administration','integrate','permission.administration.integrate',false,true),
  ('administration.jobs',   'administration','jobs', 'permission.administration.jobs',false, true),
  ('administration.audit_read','administration','audit_read','permission.administration.audit_read',false,false)
on conflict (code) do nothing;

-- -----------------------------------------------------------------------------
-- English resources for everything referenced above
--
-- erp.assert_resource_coverage() fails the build on any key without a string,
-- so this list is not decoration: a new module or permission that arrives
-- without words breaks the build rather than reaching a user as a raw key.
-- -----------------------------------------------------------------------------

insert into erp_ref.resource (key, locale, value) values
  ('module.master_data','en','Master data'),
  ('module.inventory','en','Inventory and warehouse'),
  ('module.procurement','en','Procurement'),
  ('module.planning','en','Supply chain planning'),
  ('module.production','en','Production'),
  ('module.sales','en','Sales and order management'),
  ('module.finance','en','Finance'),
  ('module.quality','en','Quality and compliance'),
  ('module.logistics','en','Logistics'),
  ('module.reporting','en','Reporting and analytics'),
  ('module.administration','en','Administration'),

  ('permission.master_data.read','en','View master data'),
  ('permission.master_data.write','en','Maintain master data'),
  ('permission.master_data.approve','en','Approve master data changes'),
  ('permission.master_data.import','en','Import master data'),
  ('permission.inventory.read','en','View stock'),
  ('permission.inventory.move','en','Move stock'),
  ('permission.inventory.adjust','en','Adjust stock'),
  ('permission.inventory.count','en','Perform stock counts'),
  ('permission.inventory.write_off','en','Write off stock'),
  ('permission.procurement.read','en','View procurement'),
  ('permission.procurement.requisition','en','Raise requisitions'),
  ('permission.procurement.order','en','Issue purchase orders'),
  ('permission.procurement.approve','en','Approve procurement'),
  ('permission.procurement.receive','en','Receive goods'),
  ('permission.procurement.match','en','Match invoices'),
  ('permission.planning.read','en','View planning'),
  ('permission.planning.forecast','en','Maintain forecasts'),
  ('permission.planning.run','en','Run planning'),
  ('permission.planning.firm','en','Firm planned orders'),
  ('permission.production.read','en','View production'),
  ('permission.production.order','en','Raise works orders'),
  ('permission.production.execute','en','Record production'),
  ('permission.production.release','en','Release production'),
  ('permission.sales.read','en','View sales'),
  ('permission.sales.order','en','Take sales orders'),
  ('permission.sales.price','en','Maintain pricing'),
  ('permission.sales.discount_approve','en','Approve discounts'),
  ('permission.sales.credit_release','en','Release credit holds'),
  ('permission.sales.despatch','en','Despatch orders'),
  ('permission.sales.invoice','en','Raise invoices'),
  ('permission.finance.read','en','View finance'),
  ('permission.finance.post','en','Post journals'),
  ('permission.finance.approve_payment','en','Approve payments'),
  ('permission.finance.close_period','en','Close periods'),
  ('permission.finance.reopen_period','en','Reopen periods'),
  ('permission.finance.configure','en','Configure finance'),
  ('permission.quality.read','en','View quality'),
  ('permission.quality.inspect','en','Record inspections'),
  ('permission.quality.disposition','en','Disposition quarantined stock'),
  ('permission.quality.release_batch','en','Release batches'),
  ('permission.quality.recall','en','Manage recalls'),
  ('permission.logistics.read','en','View logistics'),
  ('permission.logistics.plan','en','Plan shipments'),
  ('permission.logistics.despatch','en','Confirm despatch'),
  ('permission.reporting.read','en','View reports'),
  ('permission.reporting.define','en','Define reports'),
  ('permission.reporting.export','en','Export data'),
  ('permission.administration.read','en','View administration'),
  ('permission.administration.users','en','Administer users'),
  ('permission.administration.roles','en','Administer roles'),
  ('permission.administration.configure','en','Change configuration'),
  ('permission.administration.promote','en','Promote configuration'),
  ('permission.administration.integrate','en','Administer integrations'),
  ('permission.administration.jobs','en','Administer scheduled jobs'),
  ('permission.administration.audit_read','en','Read the audit trail')
on conflict (key, locale) do nothing;

-- A handful of regional variants, to demonstrate that a variant supplies only
-- genuine differences rather than a full retranslation.
insert into erp_ref.resource (key, locale, value) values
  ('permission.logistics.despatch','en-US','Confirm dispatch'),
  ('permission.sales.despatch','en-US','Dispatch orders'),
  ('permission.inventory.write_off','en-US','Write off inventory'),
  ('module.inventory','en-US','Inventory and warehousing')
on conflict (key, locale) do nothing;

-- -----------------------------------------------------------------------------
-- An illustrative legislation pack
--
-- Jurisdiction XX is the ISO 3166-1 user-assigned code, chosen precisely
-- because it is not, and cannot become, a real country. The rates below are
-- invented. This pack exists so that the conformance harness has something to
-- run and onboarding has a pack to select — and so that adding a real
-- jurisdiction later is visibly the same shape of work: rows, not code.
-- -----------------------------------------------------------------------------

insert into erp_ref.decision_point (
  code, module_code, name_key, description, input_schema, outcome_schema,
  legislation_authoritative, requires_match)
values (
  'tax.determination', 'finance', 'dp.tax.determination',
  'Which tax treatment applies to a transaction line.',
  '{"type":"object","required":["item_class","supply_type"],
    "properties":{"item_class":{"type":"string"},
                  "supply_type":{"type":"string"},
                  "net_minor":{"type":"integer"},
                  "customer_registered":{"type":"boolean"}},
    "additionalProperties":false}'::jsonb,
  '{"type":"object","required":["rate_pct","code"],
    "properties":{"rate_pct":{"type":"number"},"code":{"type":"string"}}}'::jsonb,
  -- Authoritative: a tenant may not configure its way out of a tax rate.
  true, true)
on conflict (code) do update
  set legislation_authoritative = excluded.legislation_authoritative,
      requires_match = excluded.requires_match,
      input_schema = excluded.input_schema,
      outcome_schema = excluded.outcome_schema,
      module_code = excluded.module_code;

insert into erp_ref.legislation_pack (
  code, version, jurisdiction, name_key, description, effective_from)
values (
  'example_vat', 1, 'XX', 'legislation.example_vat',
  'Illustrative value-added tax pack for the ISO user-assigned jurisdiction XX. '
  'The rates are invented and belong to no real jurisdiction. It exists to '
  'demonstrate the pack structure and to give the conformance harness something '
  'to run.',
  date '2020-01-01')
on conflict (code, version) do nothing;

insert into erp_ref.legislation_parameter (pack_code, pack_version, key, value, description) values
  ('example_vat',1,'vat.standard_rate_pct','20'::jsonb,'Illustrative standard rate'),
  ('example_vat',1,'vat.reduced_rate_pct','5'::jsonb,'Illustrative reduced rate'),
  ('example_vat',1,'vat.registration_threshold_minor','9000000'::jsonb,
   'Illustrative registration threshold, in minor units'),
  ('example_vat',1,'vat.return_frequency','"quarterly"'::jsonb,'Illustrative filing frequency')
on conflict (pack_code, pack_version, key) do nothing;

insert into erp_ref.legislation_rule
  (pack_code, pack_version, code, decision_point_code, seq, name_key, condition, outcome) values
  ('example_vat',1,'export_zero_rated','tax.determination',10,'rule.example_vat.export',
   '{"==":[{"var":"supply_type"},"export"]}'::jsonb,
   '{"rate_pct":0,"code":"E"}'::jsonb),
  ('example_vat',1,'basic_food_zero_rated','tax.determination',20,'rule.example_vat.food',
   '{"==":[{"var":"item_class"},"food_basic"]}'::jsonb,
   '{"rate_pct":0,"code":"Z"}'::jsonb),
  ('example_vat',1,'domestic_energy_reduced','tax.determination',30,'rule.example_vat.energy',
   '{"==":[{"var":"item_class"},"energy_domestic"]}'::jsonb,
   '{"rate_pct":5,"code":"R"}'::jsonb),
  ('example_vat',1,'standard_rated','tax.determination',99,'rule.example_vat.standard',
   'true'::jsonb,
   '{"rate_pct":20,"code":"S"}'::jsonb)
on conflict (pack_code, pack_version, code) do nothing;

insert into erp_ref.statutory_output
  (pack_code, pack_version, code, name_key, output_kind, frequency, definition) values
  ('example_vat',1,'vat_return','output.example_vat.return','return','quarterly',
   '{"sections":[{"box":1,"label_key":"output.example_vat.box1","source":"tax_due_on_sales"},
                 {"box":4,"label_key":"output.example_vat.box4","source":"tax_reclaimed_on_purchases"},
                 {"box":5,"label_key":"output.example_vat.box5","source":"net_tax_due"}]}'::jsonb)
on conflict (pack_code, pack_version, code) do nothing;

-- The evidence the pack computes what it claims. Each case is replayed through
-- the live rule engine by erp.run_legislation_conformance().
insert into erp_ref.conformance_case
  (pack_code, pack_version, code, decision_point_code, inputs, expected_outcome, citation, description) values
  ('example_vat',1,'export_is_zero_rated','tax.determination',
   '{"item_class":"general","supply_type":"export","net_minor":100000}'::jsonb,
   '{"rate_pct":0,"code":"E"}'::jsonb,'Illustrative pack §1',
   'Exports carry no tax regardless of what is being exported.'),
  ('example_vat',1,'basic_food_is_zero_rated','tax.determination',
   '{"item_class":"food_basic","supply_type":"domestic","net_minor":100000}'::jsonb,
   '{"rate_pct":0,"code":"Z"}'::jsonb,'Illustrative pack §2',
   'Basic foodstuffs are zero rated on domestic supply.'),
  ('example_vat',1,'domestic_energy_is_reduced','tax.determination',
   '{"item_class":"energy_domestic","supply_type":"domestic","net_minor":100000}'::jsonb,
   '{"rate_pct":5,"code":"R"}'::jsonb,'Illustrative pack §3',
   'Domestic energy attracts the reduced rate.'),
  ('example_vat',1,'anything_else_is_standard','tax.determination',
   '{"item_class":"general","supply_type":"domestic","net_minor":100000}'::jsonb,
   '{"rate_pct":20,"code":"S"}'::jsonb,'Illustrative pack §4',
   'The residual case: standard rate.'),
  -- Ordering matters and is easy to get wrong. Exported basic food could match
  -- either the export rule or the food rule; this case pins which.
  ('example_vat',1,'exported_food_takes_the_export_code','tax.determination',
   '{"item_class":"food_basic","supply_type":"export","net_minor":100000}'::jsonb,
   '{"rate_pct":0,"code":"E"}'::jsonb,'Illustrative pack §1',
   'Both rules give zero, but the export code is the one that must be reported.')
on conflict (pack_code, pack_version, code) do nothing;

insert into erp_ref.resource (key, locale, value) values
  ('dp.tax.determination','en','Tax determination'),
  ('legislation.example_vat','en','Illustrative VAT (jurisdiction XX)'),
  ('output.example_vat.return','en','VAT return'),
  ('output.example_vat.box1','en','Tax due on sales'),
  ('output.example_vat.box4','en','Tax reclaimed on purchases'),
  ('output.example_vat.box5','en','Net tax due'),
  ('rule.example_vat.export','en','Exports are zero rated'),
  ('rule.example_vat.food','en','Basic food is zero rated'),
  ('rule.example_vat.energy','en','Domestic energy is reduced rated'),
  ('rule.example_vat.standard','en','Standard rate')
on conflict (key, locale) do nothing;

-- Every referenced key now has words behind it.
select erp.assert_resource_coverage('en');
