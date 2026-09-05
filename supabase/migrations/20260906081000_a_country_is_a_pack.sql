-- A country is a pack.
--
-- The product has carried the shape of a legislation pack since B5: a pack
-- has rules on a decision point, parameters, conformance cases with a citation,
-- and statutory outputs; an entity is bound to a pack for a period; the rule
-- engine consults the bound packs first on a decision point declared
-- legislation-authoritative. One pack existed, and it was fictional by design:
-- example_vat, jurisdiction XX, rates invented. A second organisation trading
-- in Britain, Ireland and Germany could bind nothing real.
--
-- Three packs arrive here, from published rates: gb_vat (20, 5, 0), ie_vat
-- (23, 13.5, 9, 0) and de_ust (19, 7). Each value carries its provenance —
-- the statute, the schedule or the notice it was read from — because a rate
-- without a source is a guess with a decimal point, and the day it changes
-- nobody would know where to look. The provenance column is added to every
-- legislation table, filled for example_vat as well (it says, honestly, that
-- its values are invented), and made a constraint: no legislation row without
-- twenty characters of source. erp.assert_legislation_provenance() goes
-- further and refuses a current pack with no rules, no cases, no parameters,
-- no output, or a name nobody can read.
--
-- Two things the packs exposed, fixed in the same file.
--
-- A determination did not say which law decided it. erp.determine_tax()
-- inserted NULL into legislation_pack_code and legislation_pack_version, so a
-- tax figure on a German invoice was attributable to no pack and no version
-- (deferred finding 21). It now records the pack and the version that was bound
-- on the document's date when the outcome came from legislation.
--
-- A gapless invoice number was refused rather than issued. Since 20260906030000
-- a numbering rule may be declared gapless, and erp.next_document_number()
-- refuses to number a document on creation under such a rule, correctly: the
-- statutory number belongs to the invoice as issued, not to a draft that may be
-- cancelled. Nothing then allocated the number at all. de_ust requires gapless
-- numbering (§14(4) Nr. 4 UStG asks for consecutive numbers; the product takes
-- the conservative reading), so an organisation bound to it could not raise an
-- invoice. Now a document under a gapless rule is created with a provisional
-- number (DRAFT-…), and the moment its lifecycle enters a committed state the
-- number is allocated from the rule's series, inside the same transaction and
-- under the series row's lock, so a rolled-back issue consumes nothing and two
-- concurrent issues serialise. erp.document_numbering_report() and
-- erp.assert_documents_numbered() (register seq 95, per organisation) refuse a
-- committed document still carrying a provisional number, a gap in a gapless
-- document series, and an entity bound to a pack that requires gapless
-- numbering whose invoice rule is not.
--
-- What the packs do not claim. They model the standard, reduced and zero rates
-- by three item classes a tenant may assign (food, books, domestic_fuel) and an
-- export by ship-to country; they do not model distance selling, reverse charge
-- on services, margin schemes, partial exemption or the temporary rates a
-- government announces for a season. A pack is a version; a changed rate is a
-- new version, bound from its effective date, and the old one stays for the
-- documents it decided. The values were read from the authorities named in
-- each row as published when this file was written; an organisation verifies
-- them against the authority before it files, and the provenance says where.
--
-- Decision D21 (legislation is a versioned pack with provenance) is registered
-- in Phase 5 with D19–D33; its bindings are erp.assert_legislation_provenance()
-- and erp_test.assert_legislation_packs_suite() from this file.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Provenance is a column, then a constraint
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp_ref.legislation_pack      add column if not exists provenance text;
alter table erp_ref.legislation_rule      add column if not exists provenance text;
alter table erp_ref.legislation_parameter add column if not exists provenance text;
alter table erp_ref.statutory_output      add column if not exists provenance text;

update erp_ref.legislation_pack
   set provenance = 'Illustrative pack: every value is invented and belongs to no jurisdiction; it exists to show the structure and to give the conformance harness something to run.'
 where code = 'example_vat' and provenance is null;
update erp_ref.legislation_rule
   set provenance = 'Illustrative rule with an invented rate; see the pack''s own note.'
 where pack_code = 'example_vat' and provenance is null;
update erp_ref.legislation_parameter
   set provenance = 'Illustrative parameter with an invented value; see the pack''s own note.'
 where pack_code = 'example_vat' and provenance is null;
update erp_ref.statutory_output
   set provenance = 'Illustrative return with invented box numbers; see the pack''s own note.'
 where pack_code = 'example_vat' and provenance is null;
update erp_ref.conformance_case
   set citation = coalesce(nullif(btrim(citation), ''), 'Illustrative pack, invented case')
 where pack_code = 'example_vat';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Three packs
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.legislation_pack
  (code, version, jurisdiction, name_key, description, effective_from, effective_to, is_current, requires_gapless, provenance) values
  ('gb_vat', 1, 'GB', 'legislation.gb_vat',
   'United Kingdom value added tax: standard 20%, reduced 5%, zero rate, exports zero-rated. Registration threshold £90,000. Quarterly returns.',
   '2024-04-01', null, true, false,
   'Value Added Tax Act 1994 (VATA 1994): s.2(1) standard rate; s.29A and Sch 7A reduced rate; s.30 and Sch 8 zero rate; Sch 1 para 1 registration threshold as amended from 1 April 2024. Value Added Tax Regulations 1995 (SI 1995/2518) reg 14(1)(a): an invoice carries a sequential number from one or more series; reg 25 quarterly return periods. Gaps in a series are permitted where the cancelled document is retained, so requires_gapless is off.'),
  ('ie_vat', 1, 'IE', 'legislation.ie_vat',
   'Ireland value-added tax: standard 23%, reduced 13.5%, second reduced 9%, zero rate, exports and intra-Community supplies to registered persons zero-rated. Registration thresholds €85,000 goods / €42,500 services. Bi-monthly returns.',
   '2025-01-01', null, true, false,
   'Value-Added Tax Consolidation Act 2010 (VATCA 2010): s.46(1)(a) standard rate; s.46(1)(c) and Sch 3 reduced rate; s.46(1)(ca) second reduced rate; s.46(1)(b) and Sch 2 zero rate; s.2(1) registration thresholds as amended by Finance Act 2024 from 1 January 2025; s.76 bi-monthly taxable periods. Value-Added Tax Regulations 2010 (SI 639/2010) reg 20(1)(a): a sequential number from one or more series that uniquely identifies the invoice. A gap with the cancelled invoice retained is not a breach, so requires_gapless is off.'),
  ('de_ust', 1, 'DE', 'legislation.de_ust',
   'Germany Umsatzsteuer: Regelsteuersatz 19%, ermäßigter Steuersatz 7%, Ausfuhr und innergemeinschaftliche Lieferung steuerfrei. Kleinunternehmergrenze €25.000. Monatliche Voranmeldung.',
   '2025-01-01', null, true, true,
   'Umsatzsteuergesetz (UStG): §12(1) Regelsteuersatz 19%; §12(2) with Anlage 2 ermäßigter Steuersatz 7%; §4 Nr. 1(a) with §6 Ausfuhrlieferung and §4 Nr. 1(b) with §6a innergemeinschaftliche Lieferung; §19(1) Kleinunternehmer thresholds €25,000 prior year / €100,000 current year from 1 January 2025 (Jahressteuergesetz 2024); §18(1)–(2) Voranmeldung, monthly where the prior year''s tax exceeded €9,000. §14(4) Nr. 4 requires a fortlaufende Nummer, a consecutive number from one or more series; the product takes the conservative reading and requires the series gapless, although the Bundesfinanzhof (V R 4/17, 2018) held that a gap alone does not deny input tax deduction.')
on conflict (code, version) do update
  set jurisdiction = excluded.jurisdiction, description = excluded.description,
      effective_from = excluded.effective_from, is_current = excluded.is_current,
      requires_gapless = excluded.requires_gapless, provenance = excluded.provenance;

-- Rules. Order matters and the engine stops on the first match, so the export
-- rule comes first, the item classes next, the residual last. The item classes
-- are ones a tenant assigns (erp.item.item_class is the tenant's vocabulary);
-- a class nobody uses is a rule nobody reaches, which is the residual's job.
insert into erp_ref.legislation_rule
  (pack_code, pack_version, code, decision_point_code, seq, name_key, condition, outcome, stop_on_match, provenance) values
  -- United Kingdom
  ('gb_vat', 1, 'export_zero_rated', 'tax.determination', 10, 'rule.gb_vat.export',
   '{"==": [{"var": "supply_type"}, "export"]}', '{"code": "E", "rate_pct": 0}', true,
   'VATA 1994 s.30(6) and (8): a supply of goods exported to a place outside the United Kingdom is zero-rated; VAT Notice 703. Ship-to country outside GB is the fact the product reads.'),
  ('gb_vat', 1, 'food_zero_rated', 'tax.determination', 20, 'rule.gb_vat.food',
   '{"==": [{"var": "item_class"}, "food"]}', '{"code": "Z", "rate_pct": 0}', true,
   'VATA 1994 Sch 8 Group 1: food of a kind used for human consumption is zero-rated, with the excepted items (confectionery, catering, alcoholic drinks) at the standard rate; VAT Notice 701/14. The pack models the general case; an excepted item belongs in another class.'),
  ('gb_vat', 1, 'books_zero_rated', 'tax.determination', 30, 'rule.gb_vat.books',
   '{"==": [{"var": "item_class"}, "books"]}', '{"code": "Z", "rate_pct": 0}', true,
   'VATA 1994 Sch 8 Group 3: books, booklets, brochures, pamphlets, newspapers and journals, printed or (from 1 May 2020) electronic, are zero-rated; VAT Notice 701/10.'),
  ('gb_vat', 1, 'domestic_fuel_reduced', 'tax.determination', 40, 'rule.gb_vat.domestic_fuel',
   '{"==": [{"var": "item_class"}, "domestic_fuel"]}', '{"code": "R", "rate_pct": 5}', true,
   'VATA 1994 s.29A and Sch 7A Group 1: fuel and power supplied for domestic use or to a charity for non-business use is charged at 5%; VAT Notice 701/19.'),
  ('gb_vat', 1, 'standard_rated', 'tax.determination', 99, 'rule.gb_vat.standard',
   'true', '{"code": "S", "rate_pct": 20}', true,
   'VATA 1994 s.2(1): VAT is charged at 20% on the value of the supply; the rate has stood since 4 January 2011 (Finance (No. 2) Act 2010 s.3). Residual rule: anything not zero-rated, reduced or exempt.'),
  -- Ireland
  ('ie_vat', 1, 'export_zero_rated', 'tax.determination', 10, 'rule.ie_vat.export',
   '{"==": [{"var": "supply_type"}, "export"]}', '{"code": "E", "rate_pct": 0}', true,
   'VATCA 2010 s.46(1)(b) with Sch 2 para 1(1): exports of goods outside the EU and para 1(1) intra-Community supplies to persons registered in another Member State are zero-rated. Ship-to country outside IE is the fact the product reads; a distance sale to a consumer in another Member State takes the destination rate and is not modelled.'),
  ('ie_vat', 1, 'food_zero_rated', 'tax.determination', 20, 'rule.ie_vat.food',
   '{"==": [{"var": "item_class"}, "food"]}', '{"code": "Z", "rate_pct": 0}', true,
   'VATCA 2010 Sch 2 para 8: food and drink for human consumption is zero-rated, excluding the items listed there (confectionery, savoury snacks, alcohol, catering) which take the standard or reduced rate; Revenue Tax and Duty Manual, Food and Drink.'),
  ('ie_vat', 1, 'books_zero_rated', 'tax.determination', 30, 'rule.ie_vat.books',
   '{"==": [{"var": "item_class"}, "books"]}', '{"code": "Z", "rate_pct": 0}', true,
   'VATCA 2010 Sch 2 para 9: printed books and booklets are zero-rated; electronic books and newspapers have been zero-rated since 1 January 2023 (Finance Act 2022).'),
  ('ie_vat', 1, 'domestic_fuel_reduced', 'tax.determination', 40, 'rule.ie_vat.domestic_fuel',
   '{"==": [{"var": "item_class"}, "domestic_fuel"]}', '{"code": "R", "rate_pct": 13.5}', true,
   'VATCA 2010 s.46(1)(c) with Sch 3 para 17: fuel for domestic heating and electricity take the reduced rate of 13.5%. Gas and electricity have carried a temporary second reduced rate of 9% by successive Finance Acts; the pack models the statutory rate and a temporary rate is a version bound for its dates.'),
  ('ie_vat', 1, 'standard_rated', 'tax.determination', 99, 'rule.ie_vat.standard',
   'true', '{"code": "S", "rate_pct": 23}', true,
   'VATCA 2010 s.46(1)(a): the standard rate is 23%, in force since 1 January 2012 (Finance Act 2012). Residual rule.'),
  -- Germany
  ('de_ust', 1, 'export_tax_free', 'tax.determination', 10, 'rule.de_ust.export',
   '{"==": [{"var": "supply_type"}, "export"]}', '{"code": "E", "rate_pct": 0}', true,
   'UStG §4 Nr. 1(a) with §6: an Ausfuhrlieferung to a third country is steuerfrei; §4 Nr. 1(b) with §6a: an innergemeinschaftliche Lieferung to a registered customer in another Member State is steuerfrei. Ship-to country outside DE is the fact the product reads.'),
  ('de_ust', 1, 'food_reduced', 'tax.determination', 20, 'rule.de_ust.food',
   '{"==": [{"var": "item_class"}, "food"]}', '{"code": "R", "rate_pct": 7}', true,
   'UStG §12(2) Nr. 1 with Anlage 2 Nr. 1–33: Lebensmittel take the ermäßigter Steuersatz of 7%; drinks and restaurant services are excepted and take 19%.'),
  ('de_ust', 1, 'books_reduced', 'tax.determination', 30, 'rule.de_ust.books',
   '{"==": [{"var": "item_class"}, "books"]}', '{"code": "R", "rate_pct": 7}', true,
   'UStG §12(2) Nr. 1 with Anlage 2 Nr. 49: Bücher, Zeitungen und Zeitschriften take 7%; §12(2) Nr. 14 extends it to electronic publications from 18 December 2019.'),
  ('de_ust', 1, 'standard_rated', 'tax.determination', 99, 'rule.de_ust.standard',
   'true', '{"code": "S", "rate_pct": 19}', true,
   'UStG §12(1): the Regelsteuersatz is 19%, in force since 1 January 2007 (Haushaltsbegleitgesetz 2006), with the temporary 16% of 1 July to 31 December 2020 ended. Residual rule; domestic energy is standard-rated in Germany, the temporary 7% on gas and heat having ended on 31 March 2024.')
on conflict (pack_code, pack_version, code) do update
  set seq = excluded.seq, condition = excluded.condition, outcome = excluded.outcome,
      stop_on_match = excluded.stop_on_match, provenance = excluded.provenance;

insert into erp_ref.legislation_parameter (pack_code, pack_version, key, value, name_key, description, provenance) values
  ('gb_vat', 1, 'vat.standard_rate_pct', '20', null, 'Standard rate', 'VATA 1994 s.2(1).'),
  ('gb_vat', 1, 'vat.reduced_rate_pct', '5', null, 'Reduced rate', 'VATA 1994 s.29A and Sch 7A.'),
  ('gb_vat', 1, 'vat.zero_rate_pct', '0', null, 'Zero rate', 'VATA 1994 s.30 and Sch 8.'),
  ('gb_vat', 1, 'vat.registration_threshold_minor', '9000000', null, 'Registration threshold, taxable turnover in a rolling twelve months, in pence', 'VATA 1994 Sch 1 para 1(1)(a) as amended by the Value Added Tax (Increase of Registration Limits) Order 2024: £90,000 from 1 April 2024.'),
  ('gb_vat', 1, 'vat.return_frequency', '"quarterly"', null, 'Return frequency', 'VAT Regulations 1995 reg 25(1): quarterly prescribed accounting periods by default; monthly and annual accounting on application.'),
  ('gb_vat', 1, 'invoice.sequential_number', 'true', null, 'An invoice carries a sequential number', 'VAT Regulations 1995 reg 14(1)(a).'),
  ('ie_vat', 1, 'vat.standard_rate_pct', '23', null, 'Standard rate', 'VATCA 2010 s.46(1)(a).'),
  ('ie_vat', 1, 'vat.reduced_rate_pct', '13.5', null, 'Reduced rate', 'VATCA 2010 s.46(1)(c) and Sch 3.'),
  ('ie_vat', 1, 'vat.second_reduced_rate_pct', '9', null, 'Second reduced rate', 'VATCA 2010 s.46(1)(ca).'),
  ('ie_vat', 1, 'vat.zero_rate_pct', '0', null, 'Zero rate', 'VATCA 2010 s.46(1)(b) and Sch 2.'),
  ('ie_vat', 1, 'vat.registration_threshold_goods_minor', '8500000', null, 'Registration threshold for supplies of goods, in cent', 'VATCA 2010 s.2(1) as amended by Finance Act 2024: €85,000 from 1 January 2025.'),
  ('ie_vat', 1, 'vat.registration_threshold_services_minor', '4250000', null, 'Registration threshold for supplies of services, in cent', 'VATCA 2010 s.2(1) as amended by Finance Act 2024: €42,500 from 1 January 2025.'),
  ('ie_vat', 1, 'vat.return_frequency', '"bimonthly"', null, 'Return frequency', 'VATCA 2010 s.76(1): a taxable period is two months, January–February onwards; Revenue may allow longer periods.'),
  ('ie_vat', 1, 'invoice.sequential_number', 'true', null, 'An invoice carries a sequential number', 'VAT Regulations 2010 (SI 639/2010) reg 20(1)(a).'),
  ('de_ust', 1, 'vat.standard_rate_pct', '19', null, 'Regelsteuersatz', 'UStG §12(1).'),
  ('de_ust', 1, 'vat.reduced_rate_pct', '7', null, 'Ermäßigter Steuersatz', 'UStG §12(2) with Anlage 2.'),
  ('de_ust', 1, 'vat.small_business_threshold_prior_year_minor', '2500000', null, 'Kleinunternehmer threshold, prior-year turnover, in cent', 'UStG §19(1) as amended by the Jahressteuergesetz 2024: €25,000 from 1 January 2025.'),
  ('de_ust', 1, 'vat.small_business_threshold_current_year_minor', '10000000', null, 'Kleinunternehmer threshold, current-year turnover, in cent', 'UStG §19(1) as amended by the Jahressteuergesetz 2024: €100,000 from 1 January 2025.'),
  ('de_ust', 1, 'vat.return_frequency', '"monthly"', null, 'Voranmeldung frequency', 'UStG §18(2): monthly where the prior year''s tax exceeded €9,000 (from 2025), otherwise quarterly; the pack takes monthly as the default for a trading company.'),
  ('de_ust', 1, 'invoice.sequential_number', 'true', null, 'An invoice carries a consecutive number', 'UStG §14(4) Nr. 4: eine fortlaufende Nummer mit einer oder mehreren Zahlenreihen.')
on conflict (pack_code, pack_version, key) do update
  set value = excluded.value, description = excluded.description, provenance = excluded.provenance;

insert into erp_ref.conformance_case
  (pack_code, pack_version, code, name_key, description, decision_point_code, inputs, expected_outcome, citation) values
  ('gb_vat', 1, 'export_is_zero_rated', null, 'Goods shipped outside the United Kingdom carry no VAT whatever they are.', 'tax.determination',
   '{"net_minor": 100000, "item_class": "standard", "supply_type": "export"}', '{"code": "E", "rate_pct": 0}', 'VATA 1994 s.30(6)'),
  ('gb_vat', 1, 'food_is_zero_rated', null, 'Food for human consumption supplied at home is zero-rated.', 'tax.determination',
   '{"net_minor": 100000, "item_class": "food", "supply_type": "domestic"}', '{"code": "Z", "rate_pct": 0}', 'VATA 1994 Sch 8 Group 1'),
  ('gb_vat', 1, 'books_are_zero_rated', null, 'Books supplied at home are zero-rated.', 'tax.determination',
   '{"net_minor": 100000, "item_class": "books", "supply_type": "domestic"}', '{"code": "Z", "rate_pct": 0}', 'VATA 1994 Sch 8 Group 3'),
  ('gb_vat', 1, 'domestic_fuel_is_reduced', null, 'Domestic fuel and power take the 5% rate.', 'tax.determination',
   '{"net_minor": 100000, "item_class": "domestic_fuel", "supply_type": "domestic"}', '{"code": "R", "rate_pct": 5}', 'VATA 1994 Sch 7A Group 1'),
  ('gb_vat', 1, 'anything_else_is_standard', null, 'The residual case: 20%.', 'tax.determination',
   '{"net_minor": 100000, "item_class": "standard", "supply_type": "domestic"}', '{"code": "S", "rate_pct": 20}', 'VATA 1994 s.2(1)'),
  ('ie_vat', 1, 'export_is_zero_rated', null, 'Goods shipped outside Ireland carry no VAT.', 'tax.determination',
   '{"net_minor": 100000, "item_class": "standard", "supply_type": "export"}', '{"code": "E", "rate_pct": 0}', 'VATCA 2010 Sch 2 para 1'),
  ('ie_vat', 1, 'food_is_zero_rated', null, 'Food for human consumption supplied at home is zero-rated.', 'tax.determination',
   '{"net_minor": 100000, "item_class": "food", "supply_type": "domestic"}', '{"code": "Z", "rate_pct": 0}', 'VATCA 2010 Sch 2 para 8'),
  ('ie_vat', 1, 'books_are_zero_rated', null, 'Books supplied at home are zero-rated.', 'tax.determination',
   '{"net_minor": 100000, "item_class": "books", "supply_type": "domestic"}', '{"code": "Z", "rate_pct": 0}', 'VATCA 2010 Sch 2 para 9'),
  ('ie_vat', 1, 'domestic_fuel_is_reduced', null, 'Domestic fuel takes the 13.5% rate.', 'tax.determination',
   '{"net_minor": 100000, "item_class": "domestic_fuel", "supply_type": "domestic"}', '{"code": "R", "rate_pct": 13.5}', 'VATCA 2010 Sch 3 para 17'),
  ('ie_vat', 1, 'anything_else_is_standard', null, 'The residual case: 23%.', 'tax.determination',
   '{"net_minor": 100000, "item_class": "standard", "supply_type": "domestic"}', '{"code": "S", "rate_pct": 23}', 'VATCA 2010 s.46(1)(a)'),
  ('de_ust', 1, 'export_is_tax_free', null, 'Goods shipped outside Germany are steuerfrei.', 'tax.determination',
   '{"net_minor": 100000, "item_class": "standard", "supply_type": "export"}', '{"code": "E", "rate_pct": 0}', 'UStG §4 Nr. 1'),
  ('de_ust', 1, 'food_is_reduced', null, 'Lebensmittel take the 7% rate.', 'tax.determination',
   '{"net_minor": 100000, "item_class": "food", "supply_type": "domestic"}', '{"code": "R", "rate_pct": 7}', 'UStG §12(2) Nr. 1, Anlage 2'),
  ('de_ust', 1, 'books_are_reduced', null, 'Bücher take the 7% rate.', 'tax.determination',
   '{"net_minor": 100000, "item_class": "books", "supply_type": "domestic"}', '{"code": "R", "rate_pct": 7}', 'UStG §12(2) Nr. 1, Anlage 2 Nr. 49'),
  ('de_ust', 1, 'domestic_fuel_is_standard', null, 'Domestic energy is standard-rated in Germany; the residual rule must catch it.', 'tax.determination',
   '{"net_minor": 100000, "item_class": "domestic_fuel", "supply_type": "domestic"}', '{"code": "S", "rate_pct": 19}', 'UStG §12(1)'),
  ('de_ust', 1, 'anything_else_is_standard', null, 'The residual case: 19%.', 'tax.determination',
   '{"net_minor": 100000, "item_class": "standard", "supply_type": "domestic"}', '{"code": "S", "rate_pct": 19}', 'UStG §12(1)')
on conflict (pack_code, pack_version, code) do update
  set inputs = excluded.inputs, expected_outcome = excluded.expected_outcome, citation = excluded.citation, description = excluded.description;

insert into erp_ref.statutory_output
  (pack_code, pack_version, code, name_key, output_kind, definition, frequency, description, provenance) values
  ('gb_vat', 1, 'vat_return', 'output.gb_vat.return', 'return',
   '{"sections": [{"box": "1", "source": "tax_due_on_sales", "label_key": "output.gb_vat.box1"},
                  {"box": "4", "source": "tax_reclaimed_on_purchases", "label_key": "output.gb_vat.box4"},
                  {"box": "5", "source": "net_tax_due", "label_key": "output.gb_vat.box5"}]}',
   'quarterly', 'The VAT Return (form VAT 100), boxes 1, 4 and 5 of nine; boxes 2, 3 and 6–9 are later versions.',
   'VAT Regulations 1995 reg 25 and the VAT Return form VAT 100; HMRC VAT Notice 700/12 describes the nine boxes.'),
  ('ie_vat', 1, 'vat3', 'output.ie_vat.vat3', 'return',
   '{"sections": [{"box": "T1", "source": "tax_due_on_sales", "label_key": "output.ie_vat.t1"},
                  {"box": "T2", "source": "tax_reclaimed_on_purchases", "label_key": "output.ie_vat.t2"},
                  {"box": "T3", "source": "net_tax_due", "label_key": "output.ie_vat.t3"}]}',
   'bimonthly', 'The VAT3 return: T1 VAT on sales, T2 VAT on purchases, T3 net payable (T4 repayable when negative).',
   'VATCA 2010 s.76 and the Revenue VAT3 return as filed through ROS.'),
  ('de_ust', 1, 'voranmeldung', 'output.de_ust.voranmeldung', 'return',
   '{"sections": [{"box": "81", "source": "taxable_at_standard_rate", "label_key": "output.de_ust.kz81"},
                  {"box": "86", "source": "taxable_at_reduced_rate", "label_key": "output.de_ust.kz86"},
                  {"box": "66", "source": "tax_reclaimed_on_purchases", "label_key": "output.de_ust.kz66"},
                  {"box": "83", "source": "net_tax_due", "label_key": "output.de_ust.kz83"}]}',
   'monthly', 'The Umsatzsteuer-Voranmeldung: Kennzahl 81 (Umsätze 19%), 86 (Umsätze 7%), 66 (Vorsteuer), 83 (verbleibende Zahllast).',
   'UStG §18(1) and the Umsatzsteuer-Voranmeldung form published by the Bundesministerium der Finanzen, filed through ELSTER.')
on conflict (pack_code, pack_version, code) do update
  set definition = excluded.definition, frequency = excluded.frequency, description = excluded.description, provenance = excluded.provenance;

-- Names people read. The coverage gate reads the pack and output name keys;
-- the rule and box keys are added so a screen listing a pack's rules is not a
-- screen listing key strings.
insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('legislation.gb_vat', 'en', 'United Kingdom VAT', null, 'Legislation pack name'),
  ('legislation.ie_vat', 'en', 'Ireland VAT', null, 'Legislation pack name'),
  ('legislation.de_ust', 'en', 'Germany Umsatzsteuer (VAT)', null, 'Legislation pack name'),
  ('rule.gb_vat.export', 'en', 'Exports are zero-rated', null, null),
  ('rule.gb_vat.food', 'en', 'Food is zero-rated', null, null),
  ('rule.gb_vat.books', 'en', 'Books are zero-rated', null, null),
  ('rule.gb_vat.domestic_fuel', 'en', 'Domestic fuel is reduced-rated', null, null),
  ('rule.gb_vat.standard', 'en', 'Standard rate', null, null),
  ('rule.ie_vat.export', 'en', 'Exports and intra-Community supplies are zero-rated', null, null),
  ('rule.ie_vat.food', 'en', 'Food is zero-rated', null, null),
  ('rule.ie_vat.books', 'en', 'Books are zero-rated', null, null),
  ('rule.ie_vat.domestic_fuel', 'en', 'Domestic fuel is reduced-rated', null, null),
  ('rule.ie_vat.standard', 'en', 'Standard rate', null, null),
  ('rule.de_ust.export', 'en', 'Exports and intra-Community supplies are tax-free', null, null),
  ('rule.de_ust.food', 'en', 'Food is reduced-rated', null, null),
  ('rule.de_ust.books', 'en', 'Books are reduced-rated', null, null),
  ('rule.de_ust.standard', 'en', 'Standard rate', null, null),
  ('output.gb_vat.return', 'en', 'VAT Return', null, null),
  ('output.gb_vat.box1', 'en', 'Box 1: VAT due on sales', null, null),
  ('output.gb_vat.box4', 'en', 'Box 4: VAT reclaimed on purchases', null, null),
  ('output.gb_vat.box5', 'en', 'Box 5: net VAT due', null, null),
  ('output.ie_vat.vat3', 'en', 'VAT3 return', null, null),
  ('output.ie_vat.t1', 'en', 'T1: VAT on sales', null, null),
  ('output.ie_vat.t2', 'en', 'T2: VAT on purchases', null, null),
  ('output.ie_vat.t3', 'en', 'T3: net VAT payable', null, null),
  ('output.de_ust.voranmeldung', 'en', 'Umsatzsteuer-Voranmeldung (advance VAT return)', null, null),
  ('output.de_ust.kz81', 'en', 'Kz 81: supplies at the standard rate', null, null),
  ('output.de_ust.kz86', 'en', 'Kz 86: supplies at the reduced rate', null, null),
  ('output.de_ust.kz66', 'en', 'Kz 66: input tax', null, null),
  ('output.de_ust.kz83', 'en', 'Kz 83: net tax payable', null, null)
on conflict (key, locale) do update set value = excluded.value;

-- Now that every row has a source, the column becomes a constraint.
alter table erp_ref.legislation_pack      alter column provenance set not null;
alter table erp_ref.legislation_rule      alter column provenance set not null;
alter table erp_ref.legislation_parameter alter column provenance set not null;
alter table erp_ref.statutory_output      alter column provenance set not null;
alter table erp_ref.conformance_case      alter column citation   set not null;
alter table erp_ref.legislation_pack      add constraint legislation_pack_provenance_check      check (length(btrim(provenance)) >= 20);
alter table erp_ref.legislation_rule      add constraint legislation_rule_provenance_check      check (length(btrim(provenance)) >= 20);
alter table erp_ref.legislation_parameter add constraint legislation_parameter_provenance_check check (length(btrim(provenance)) >= 8);
alter table erp_ref.statutory_output      add constraint statutory_output_provenance_check      check (length(btrim(provenance)) >= 20);
alter table erp_ref.conformance_case      add constraint conformance_case_citation_check        check (length(btrim(citation)) >= 8);

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A pack is complete and sourced, and the assertion says so
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.legislation_provenance_report()
returns table(pack_code text, pack_version integer, finding text)
language sql
stable
set search_path = ''
as $$
  with current_packs as (
    select lp.code, lp.version, lp.name_key from erp_ref.legislation_pack lp where lp.is_current
  )
  select cp.code, cp.version, 'a current pack with no rule on any decision point'
    from current_packs cp
   where not exists (select 1 from erp_ref.legislation_rule r where r.pack_code = cp.code and r.pack_version = cp.version)
  union all
  select cp.code, cp.version, 'a current pack with no conformance case: nothing proves its rules say what the law says'
    from current_packs cp
   where not exists (select 1 from erp_ref.conformance_case c where c.pack_code = cp.code and c.pack_version = cp.version)
  union all
  select cp.code, cp.version, 'a current pack with no parameter'
    from current_packs cp
   where not exists (select 1 from erp_ref.legislation_parameter p where p.pack_code = cp.code and p.pack_version = cp.version)
  union all
  select cp.code, cp.version, 'a current pack with no statutory output: it decides tax nobody can file'
    from current_packs cp
   where not exists (select 1 from erp_ref.statutory_output o where o.pack_code = cp.code and o.pack_version = cp.version)
  union all
  select cp.code, cp.version, format('the pack''s name key %s has no en resource', cp.name_key)
    from current_packs cp
   where not exists (select 1 from erp_ref.resource res where res.key = cp.name_key and res.locale = 'en')
  union all
  select r.pack_code, r.pack_version, format('rule %s names key %s, which has no en resource', r.code, r.name_key)
    from erp_ref.legislation_rule r
    join current_packs cp on cp.code = r.pack_code and cp.version = r.pack_version
   where r.name_key is not null
     and not exists (select 1 from erp_ref.resource res where res.key = r.name_key and res.locale = 'en')
  union all
  select o.pack_code, o.pack_version, format('output %s labels a section with key %s, which has no en resource', o.code, s ->> 'label_key')
    from erp_ref.statutory_output o
    join current_packs cp on cp.code = o.pack_code and cp.version = o.pack_version
    cross join lateral jsonb_array_elements(coalesce(o.definition -> 'sections', '[]'::jsonb)) s
   where s ->> 'label_key' is not null
     and not exists (select 1 from erp_ref.resource res where res.key = s ->> 'label_key' and res.locale = 'en')
  union all
  select c.pack_code, c.pack_version, format('conformance case %s expects an outcome its own rules do not produce', c.code)
    from erp_ref.conformance_case c
    join current_packs cp on cp.code = c.pack_code and cp.version = c.pack_version
   where not exists (
     select 1 from erp_ref.legislation_rule r
      where r.pack_code = c.pack_code and r.pack_version = c.pack_version
        and r.decision_point_code = c.decision_point_code
        and r.outcome @> c.expected_outcome)
  union all
  -- A pack that requires gapless numbering must say where the law says so.
  select cp.code, cp.version, 'the pack requires gapless numbering and no parameter records the sequential-number requirement'
    from current_packs cp
    join erp_ref.legislation_pack lp on lp.code = cp.code and lp.version = cp.version
   where lp.requires_gapless
     and not exists (select 1 from erp_ref.legislation_parameter p
                      where p.pack_code = cp.code and p.pack_version = cp.version and p.key = 'invoice.sequential_number')
$$;
revoke all on function erp.legislation_provenance_report() from public, anon, authenticated;

create or replace function erp.assert_legislation_provenance()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count  integer;
  v_detail text;
begin
  select count(*), string_agg(format('  %s v%s: %s', r.pack_code, r.pack_version, r.finding), E'\n')
    into v_count, v_detail
    from erp.legislation_provenance_report() r;
  if v_count > 0 then
    raise exception E'CLOVEERP_LEGISLATION_UNSOURCED: % finding(s)\n%', v_count, v_detail
      using errcode = '23514',
            hint = 'Every current legislation pack carries rules, cases, parameters, an output and readable names, each with its source; complete the pack in a migration.';
  end if;
  return format('legislation: %s current pack(s) in %s jurisdiction(s), %s rule(s) and %s case(s), every value sourced',
                (select count(*) from erp_ref.legislation_pack where is_current),
                (select count(distinct jurisdiction) from erp_ref.legislation_pack where is_current),
                (select count(*) from erp_ref.legislation_rule r join erp_ref.legislation_pack lp on lp.code = r.pack_code and lp.version = r.pack_version where lp.is_current),
                (select count(*) from erp_ref.conformance_case c join erp_ref.legislation_pack lp on lp.code = c.pack_code and lp.version = c.pack_version where lp.is_current));
end;
$$;
revoke all on function erp.assert_legislation_provenance() from public, anon, authenticated;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('legislation_provenance', 'Every legislation value names its source', 'assertion', 'platform',
   'assert_legislation_provenance', '', 'legislation_provenance_report', '',
   'Every current legislation pack has rules, conformance cases, parameters, a statutory output and readable names, and every value carries the statute or notice it was read from.', true, 96)
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name,
      detail_function = excluded.detail_function, blurb = excluded.blurb, seq = excluded.seq;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. A determination names the law that made it
-- ═════════════════════════════════════════════════════════════════════════════

do $tax$
declare
  v_def text := pg_get_functiondef('erp.determine_tax(uuid)'::regprocedure);
  v_n1  text := E'  v_id     uuid;\nbegin';
  v_n2  text := E'  v_rate := (o.outcome ->> ''rate_pct'')::numeric;';
  v_n3  text := E'    taxable_minor, tax_minor, currency, jurisdiction, rule_code,\n'
             || E'    determination_inputs, rule_evaluation_id, determined_at)';
  v_n4  text := E'          o.rule_code, v_facts, null, now())';
begin
  if (select count(*) from regexp_matches(v_def, E'  v_id     uuid;\nbegin', 'g')) <> 1
     or (select count(*) from regexp_matches(v_def, 'v_rate := \(o\.outcome ->> ''rate_pct''\)::numeric;', 'g')) <> 1
     or position(v_n3 in v_def) = 0
     or (select count(*) from regexp_matches(v_def, 'o\.rule_code, v_facts, null, now\(\)\)', 'g')) <> 1 then
    raise exception 'CLOVEERP_DETERMINE_TAX_UNRECOGNISED: erp.determine_tax is not the body this migration patches';
  end if;

  v_def := replace(v_def, v_n1,
       E'  v_id     uuid;\n'
    || E'  v_pack   text;\n'
    || E'  v_pack_version integer;\n'
    || E'begin');
  v_def := replace(v_def, v_n2,
       E'  if o.source like ''legislation:%'' then\n'
    || E'    v_pack := split_part(o.source, '':'', 2);\n'
    || E'    select b.pack_version into v_pack_version\n'
    || E'      from erp.bound_legislation_packs(d.entity_id, d.document_date) b\n'
    || E'     where b.pack_code = v_pack;\n'
    || E'  end if;\n'
    || v_n2);
  v_def := replace(v_def, v_n3,
       E'    taxable_minor, tax_minor, currency, jurisdiction, rule_code,\n'
    || E'    legislation_pack_code, legislation_pack_version,\n'
    || E'    determination_inputs, rule_evaluation_id, determined_at)');
  v_def := replace(v_def, v_n4,
       E'          o.rule_code, v_pack, v_pack_version, v_facts, null, now())');
  execute v_def;
end
$tax$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. A gapless number is allocated when the document commits
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.provisional_document_number()
returns text
language sql
volatile
set search_path = ''
as $$
  select 'DRAFT-' || upper(left(replace(gen_random_uuid()::text, '-', ''), 12))
$$;
revoke all on function erp.provisional_document_number() from public, anon, authenticated;

comment on function erp.provisional_document_number is
  'The number a document under a gapless rule carries until it commits. Unique '
  'enough for the unique index, recognisable by its prefix, never in a series.';

create or replace function erp.allocate_gapless_number(p_document_id uuid)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  nr       erp.numbering_rule%rowtype;
  v_period text;
  a        record;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  -- Numbered already: by a rule that was not gapless at creation, or by an
  -- earlier committed state in the same lifecycle.
  if d.document_number not like 'DRAFT-%' then
    return d.document_number;
  end if;

  select r.* into nr
    from erp.numbering_rule r
    join erp.document_type dt on dt.numbering_rule_id = r.id
   where dt.tenant_id = v_tenant and dt.id = d.document_type_id and r.tenant_id = v_tenant
     for update of r;
  if not found then
    raise exception 'CLOVEERP_DOCUMENT_NO_NUMBERING: % has no numbering rule bound', d.document_number
      using errcode = '23514',
            hint = 'The document type lost its numbering rule after this document was created; promote a rule for the type.';
  end if;

  -- The period is the day of issue, as the statute counts it, not the day the
  -- draft was opened.
  v_period := erp.number_period(nr.reset_period, current_date);
  select * into a from erp.allocate_number(
    'rule:' || nr.id::text, nr.prefix, nr.suffix, nr.pad_to, nr.reset_period, current_date,
    case when nr.current_period = v_period then nr.next_value else 1 end);

  update erp.numbering_rule
     set next_value = a.value + 1, current_period = a.period, updated_at = now()
   where id = nr.id;

  update erp.document
     set document_number = a.number, updated_at = now()
   where id = d.id;

  return a.number;
end;
$$;
revoke all on function erp.allocate_gapless_number(uuid) from public, anon, authenticated;

comment on function erp.allocate_gapless_number is
  'Gives a document its number from its rule''s series at the moment it '
  'commits. The series row is locked by the allocation and held to commit, so '
  'two issues serialise and a rolled-back issue consumes nothing — which is '
  'what gapless means, and why this is not a deferred trigger: the finance '
  'bridge that runs later in the same transaction must see the real number.';

create or replace function erp.number_document_on_commit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_committed boolean;
  v_number    text;
begin
  select s.is_committed into v_committed from erp.state s where s.id = new.current_state_id;
  if not coalesce(v_committed, false) then
    return null;
  end if;
  select doc.document_number into v_number
    from erp.document doc
   where doc.tenant_id = new.tenant_id and doc.id = new.object_id;
  if v_number is null or v_number not like 'DRAFT-%' then
    return null;
  end if;
  perform erp.allocate_gapless_number(new.object_id);
  return null;
end;
$$;
revoke all on function erp.number_document_on_commit() from public, anon, authenticated;

drop trigger if exists t_object_state_document_number on erp.object_state;
create trigger t_object_state_document_number
  after update of current_state_id on erp.object_state
  for each row
  when (new.object_type = 'document' and new.current_state_id is distinct from old.current_state_id)
  execute function erp.number_document_on_commit();

-- Creation takes a provisional number under a gapless rule instead of
-- refusing. erp.next_document_number() keeps its refusal: it is the eager
-- path, and nothing may take a gapless number eagerly.
do $create$
declare
  v_def text := pg_get_functiondef('erp.create_document(text,uuid,uuid,uuid,date,character,text,jsonb)'::regprocedure);
  v_n1  text := E'  v_number := erp.next_document_number(dt.numbering_rule_id);';
begin
  if (select count(*) from regexp_matches(v_def, 'v_number := erp\.next_document_number\(dt\.numbering_rule_id\);', 'g')) <> 1 then
    raise exception 'CLOVEERP_CREATE_DOCUMENT_UNRECOGNISED: erp.create_document is not the body this migration patches';
  end if;
  v_def := replace(v_def, v_n1,
       E'  if exists (select 1 from erp.numbering_rule nr\n'
    || E'              where nr.id = dt.numbering_rule_id and nr.is_gapless) then\n'
    || E'    v_number := erp.provisional_document_number();\n'
    || E'  else\n'
    || E'    v_number := erp.next_document_number(dt.numbering_rule_id);\n'
    || E'  end if;');
  execute v_def;
end
$create$;

-- The rule, reported and asserted per organisation.
create or replace function erp.document_numbering_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id)
  select 'a committed document still carries a provisional number',
         doc.document_number,
         format('%s %s entered %s and was never numbered from %s', dt.code, doc.id, s.code, nr.code)
    from t
    join erp.document doc on doc.tenant_id = t.tenant_id
    join erp.document_type dt on dt.id = doc.document_type_id
    left join erp.numbering_rule nr on nr.id = dt.numbering_rule_id
    join erp.object_state os on os.tenant_id = doc.tenant_id and os.object_type = 'document' and os.object_id = doc.id
    join erp.state s on s.id = os.current_state_id
   where doc.document_number like 'DRAFT-%' and s.is_committed
  union all
  select 'a provisional number under a rule that is not gapless',
         doc.document_number,
         format('%s %s was opened under %s while it was gapless; the rule no longer is, so nothing will number this document', dt.code, doc.id, nr.code)
    from t
    join erp.document doc on doc.tenant_id = t.tenant_id
    join erp.document_type dt on dt.id = doc.document_type_id
    join erp.numbering_rule nr on nr.id = dt.numbering_rule_id
   where doc.document_number like 'DRAFT-%' and not nr.is_gapless and not doc.is_cancelled
  union all
  select 'an entity bound to legislation requiring gapless numbering has an invoice rule that is not gapless',
         nr.code,
         format('%s is bound to %s v%s, which requires a gapless series; document type %s numbers from %s, which is not', e.code, b.pack_code, b.pack_version, dt.code, nr.code)
    from t
    join erp.entity_legislation_binding b on b.tenant_id = t.tenant_id and b.status = 'active'
     and daterange(b.effective_from, b.effective_to, '[)') @> current_date
    join erp_ref.legislation_pack lp on lp.code = b.pack_code and lp.version = b.pack_version and lp.requires_gapless
    join erp.entity e on e.id = b.entity_id
    join erp.document_type dt on dt.tenant_id = t.tenant_id and dt.status = 'active'
     and dt.base_type_code in ('invoice_reference', 'credit_reference')
     and (dt.entity_id = b.entity_id or dt.entity_id is null)
    join erp.numbering_rule nr on nr.id = dt.numbering_rule_id
   where not nr.is_gapless
  union all
  select g.finding, g.rule_code, format('%s: %s issued, %s gap(s)', g.expected, g.issued, g.gaps)
    from erp.sequence_gap_report() g
   where g.rule_code not like 'ledger:%'
     and g.finding in ('numbers are missing from a statutorily gapless series',
                       'the same number is on more than one record')
$$;
revoke all on function erp.document_numbering_report() from public, anon, authenticated;

create or replace function erp.assert_documents_numbered()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count  integer;
  v_detail text;
begin
  select count(*), string_agg(format('  %s — %s: %s', r.finding, r.reference, r.detail), E'\n')
    into v_count, v_detail
    from erp.document_numbering_report() r;
  if v_count > 0 then
    raise exception E'CLOVEERP_DOCUMENTS_UNNUMBERED: % finding(s)\n%', v_count, v_detail
      using errcode = '23514',
            hint = 'A committed document takes its number from its rule''s series at commit; a gapless series has no holes; an entity under gapless legislation numbers its invoices from a gapless rule. Promote the rule, or issue the document.';
  end if;
  return format('document numbering: %s committed document(s) numbered, %s gapless rule(s), no provisional number left behind',
                (select count(*) from erp.document doc
                   join erp.object_state os on os.tenant_id = doc.tenant_id and os.object_type = 'document' and os.object_id = doc.id
                   join erp.state s on s.id = os.current_state_id
                  where doc.tenant_id = erp.require_tenant_id() and s.is_committed),
                (select count(*) from erp.numbering_rule nr where nr.tenant_id = erp.require_tenant_id() and nr.is_gapless));
end;
$$;
revoke all on function erp.assert_documents_numbered() from public, anon, authenticated;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('documents_numbered', 'Every committed document has its number', 'assertion', 'tenant',
   'assert_documents_numbered', '', 'document_numbering_report', '',
   'A document under a gapless rule is numbered the moment it commits and never before; a gapless series has no holes; an entity bound to legislation that requires gapless numbering numbers its invoices from a gapless rule. Per organisation.', true, 95)
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name,
      detail_function = excluded.detail_function, blurb = excluded.blurb, seq = excluded.seq;

update erp_ref.part5_capability
   set artefacts = array['erp.determine_tax(uuid)', 'erp.tax_report(date,date,uuid)', 'erp.tax_determination',
                         'erp.configure_tax(character,numeric)', 'erp_ref.legislation_pack',
                         'erp.assert_legislation_provenance()', 'erp.assert_documents_numbered()']
 where code = '5.7.tax';

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The suites
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.legislation_packs_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases   integer := 0;
  v_tenant  uuid; v_admin uuid; v_token text;
  v_e1 uuid; v_e2 uuid; v_e3 uuid; v_e4 uuid;
  v_customer uuid; v_us_customer uuid; v_item uuid; v_site uuid;
  v_doc uuid; v_line uuid; v_td uuid;
  v_s uuid; v_cs uuid;
  res jsonb;
  v_msg text; v_out text;
  v_n integer;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-legislation', 'Legislation suite', 'admin@zz-legislation.test', 'Legislation Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000d4', 'admin@zz-legislation.test');
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000d4')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select e.id into v_e1 from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant order by s.code limit 1;
  select i.id into v_item from erp.item i where i.tenant_id = v_tenant and i.status = 'active' order by i.code limit 1;
  select pr.party_id into v_customer from erp.party_role pr join erp.party p on p.id = pr.party_id
   where pr.tenant_id = v_tenant and pr.role_kind = 'customer' and p.country_code = 'GB' order by p.code limit 1;

  -- 1. Three real packs, complete and sourced.
  v_cases := v_cases + 1;
  v_out := erp.assert_legislation_provenance();
  case_name := 'three jurisdictions ship as current packs, complete, and every value names its source';
  passed := (select count(*) from erp_ref.legislation_pack where is_current and code in ('gb_vat', 'ie_vat', 'de_ust')) = 3
        and (select count(*) from erp_ref.legislation_pack lp where lp.is_current and lp.requires_gapless) = 1
        and v_out like 'legislation: 4 current pack(s) in 4 jurisdiction(s)%';
  detail := v_out;
  return next;

  -- 2. The British company under gb_vat conforms.
  v_cases := v_cases + 1;
  insert into erp.entity_legislation_binding (tenant_id, entity_id, pack_code, pack_version, effective_from)
  values (v_tenant, v_e1, 'gb_vat', 1, date '2024-04-01');
  v_out := erp.assert_legislation_conformance(v_e1, null);
  case_name := 'a British company bound to gb_vat passes every conformance case the pack ships';
  passed := v_out = 'conformance: 5/5 cases passed';
  detail := v_out;
  return next;

  -- 3. An Irish company under ie_vat conforms.
  v_cases := v_cases + 1;
  v_e2 := erp.create_entity('ZZ-IE', 'Zz Ireland', 'Zz Ireland Ltd', 'EUR', 'IE', 'en-IE', 'en-IE', 1::smallint);
  insert into erp.entity_legislation_binding (tenant_id, entity_id, pack_code, pack_version, effective_from)
  values (v_tenant, v_e2, 'ie_vat', 1, date '2025-01-01');
  v_out := erp.assert_legislation_conformance(v_e2, null);
  case_name := 'an Irish company bound to ie_vat passes every conformance case the pack ships';
  passed := v_out = 'conformance: 5/5 cases passed';
  detail := v_out;
  return next;

  -- 4. A German company under de_ust conforms.
  v_cases := v_cases + 1;
  v_e3 := erp.create_entity('ZZ-DE', 'Zz Deutschland', 'Zz Deutschland GmbH', 'EUR', 'DE', 'de', 'de', 1::smallint);
  insert into erp.entity_legislation_binding (tenant_id, entity_id, pack_code, pack_version, effective_from)
  values (v_tenant, v_e3, 'de_ust', 1, date '2025-01-01');
  v_out := erp.assert_legislation_conformance(v_e3, null);
  case_name := 'a German company bound to de_ust passes every conformance case the pack ships';
  passed := v_out = 'conformance: 5/5 cases passed';
  detail := v_out;
  return next;

  -- 5. A determination on a domestic sale records the pack and version that decided it.
  v_cases := v_cases + 1;
  v_doc := erp.open_document('sales_order', v_customer, v_e1, v_site, null, null, null);
  v_line := erp.add_document_line(v_doc, v_item, 5, 2000, 'legislation suite, domestic');
  v_td := erp.determine_tax(v_line);
  case_name := 'a domestic sale is determined by gb_vat and the determination says so, with the version';
  passed := exists (select 1 from erp.tax_determination td
                     where td.id = v_td and td.legislation_pack_code = 'gb_vat' and td.legislation_pack_version = 1
                       and td.tax_code = 'S' and td.rate_pct = 20 and td.tax_minor = 2000 and td.jurisdiction = 'GB');
  detail := (select format('pack %s v%s, code %s at %s%% on %s: tax %s', td.legislation_pack_code, td.legislation_pack_version,
                           td.tax_code, td.rate_pct, td.taxable_minor, td.tax_minor) from erp.tax_determination td where td.id = v_td);
  return next;

  -- 6. An export is zero-rated by the same pack.
  v_cases := v_cases + 1;
  v_us_customer := erp.create_party('ZZ-US-CUST', 'Zz American customer', array['customer']::erp.party_role_kind[], 'US');
  v_doc := erp.open_document('sales_order', v_us_customer, v_e1, v_site, null, null, null);
  v_line := erp.add_document_line(v_doc, v_item, 5, 2000, 'legislation suite, export');
  v_td := erp.determine_tax(v_line);
  case_name := 'a sale shipped outside the jurisdiction is zero-rated as an export by the pack''s first rule';
  passed := exists (select 1 from erp.tax_determination td
                     where td.id = v_td and td.legislation_pack_code = 'gb_vat' and td.tax_code = 'E' and td.rate_pct = 0 and td.tax_minor = 0
                       and td.rule_code = 'export_zero_rated');
  detail := (select format('rule %s from %s: code %s, tax %s', td.rule_code, td.legislation_pack_code, td.tax_code, td.tax_minor)
               from erp.tax_determination td where td.id = v_td);
  return next;

  -- 7. Gapless legislation on a company whose invoice rule is not gapless is a finding.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    insert into erp.entity_legislation_binding (tenant_id, entity_id, pack_code, pack_version, effective_from)
    values (v_tenant, v_e1, 'de_ust', 1, date '2025-01-01');
    begin
      perform erp.assert_documents_numbered();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'binding a company to legislation that requires gapless numbering, with a non-gapless invoice rule, is refused by name';
  passed := coalesce(v_msg like 'CLOVEERP_DOCUMENTS_UNNUMBERED:%' and v_msg like '%sales_invoice%' and v_msg like '%de_ust%', false);
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 8. The interview binds a company to a pack by promotion.
  v_cases := v_cases + 1;
  v_s := (public.erp_start_interview('zz-legislation-shape') ->> 'session_id')::uuid;
  perform public.erp_answer_interview(v_s, 'org.multi_company', 'true'::jsonb);
  perform public.erp_answer_interview(v_s, 'org.companies', '[{"left":"ZZ-IE2","right":"Zz Ireland Two"}]'::jsonb);
  perform public.erp_answer_interview(v_s, 'org.currencies', '[{"left":"ZZ-IE2","right":"EUR"}]'::jsonb);
  perform public.erp_answer_interview(v_s, 'org.countries', '[{"left":"ZZ-IE2","right":"IE"}]'::jsonb);
  perform public.erp_answer_interview(v_s, 'org.legislation', '[{"left":"ZZ-IE2","right":"ie_vat"}]'::jsonb);
  res := public.erp_propose_from_interview(v_s);
  select (x ->> 'change_set_id')::uuid into v_cs from jsonb_array_elements(res -> 'proposals') x where x ->> 'section' = 'B.7';
  perform erp.submit_change_set(v_cs);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  select e.id into v_e4 from erp.entity e where e.tenant_id = v_tenant and e.code = 'ZZ-IE2';
  v_n := (select count(*) from erp.bound_legislation_packs(v_e4, null) b where b.pack_code = 'ie_vat' and b.pack_version = 1);
  case_name := 'the interview''s legislation answer binds the new company to ie_vat through promotion, and it conforms';
  passed := v_e4 is not null and v_n = 1
        and erp.assert_legislation_conformance(v_e4, null) = 'conformance: 5/5 cases passed';
  detail := format('ZZ-IE2 %s, bound to ie_vat: %s binding(s) in force', coalesce(v_e4::text, 'missing'), v_n);
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- 9. Undone.
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-legislation')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000d4');
  detail := 'zz-legislation rolled back with its four companies and their bindings';
  return next;

  if v_cases <> 9 then
    raise exception 'CLOVEERP_SUITE_SHRANK: legislation_packs_suite ran % cases, expected 9', v_cases;
  end if;
end;
$$;

create or replace function erp_test.assert_legislation_packs_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_fail   integer;
  v_all    integer;
  v_detail text;
begin
  create temp table if not exists _legislation_packs on commit drop as
    select * from erp_test.legislation_packs_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _legislation_packs;
  drop table _legislation_packs;
  if v_fail > 0 then
    raise exception E'CLOVEERP_LEGISLATION_PACKS_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 9 then
    raise exception 'CLOVEERP_SUITE_SHRANK: legislation_packs_suite ran % cases, expected 9', v_all;
  end if;
  return format('legislation packs: %s/%s cases passed', v_all, v_all);
end;
$$;

create or replace function erp_test.numbering_at_issue_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases   integer := 0;
  v_tenant  uuid; v_admin uuid; v_token text;
  v_e1 uuid; v_customer uuid; v_item uuid;
  v_inv1 uuid; v_inv2 uuid; v_inv3 uuid; v_inv4 uuid; v_inv5 uuid;
  v_n1 text; v_n2 text; v_n3 text; v_n4 text; v_n5 text; v_draft text;
  v_before bigint; v_after bigint;
  v_msg text; v_out text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-issue', 'Numbering at issue suite', 'admin@zz-issue.test', 'Issue Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000d5', 'admin@zz-issue.test');
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000d5')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select e.id into v_e1 from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
  select i.id into v_item from erp.item i where i.tenant_id = v_tenant and i.status = 'active' order by i.code limit 1;
  select pr.party_id into v_customer from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'customer' order by pr.party_id limit 1;

  -- The invoice series becomes gapless. Not live, so the guard lets it through.
  update erp.numbering_rule set is_gapless = true, updated_at = now()
   where tenant_id = v_tenant and code = 'sales_invoice';
  select next_value into v_before from erp.numbering_rule where tenant_id = v_tenant and code = 'sales_invoice';

  -- 1. A draft carries a provisional number.
  v_cases := v_cases + 1;
  v_inv1 := erp.open_document('sales_invoice', v_customer, v_e1, null, null, null, null);
  select document_number into v_draft from erp.document where id = v_inv1;
  case_name := 'an invoice opened under a gapless rule carries a provisional number, and the series has not moved';
  passed := v_draft like 'DRAFT-%'
        and (select next_value from erp.numbering_rule where tenant_id = v_tenant and code = 'sales_invoice') = v_before;
  detail := format('opened as %s, series still at %s', v_draft, v_before);
  return next;

  -- 2. Issue allocates the number.
  v_cases := v_cases + 1;
  perform erp.add_document_line(v_inv1, v_item, 2, 5000, 'numbering at issue');
  perform erp.transition_document(v_inv1, 'issue', 'numbering suite');
  select document_number into v_n1 from erp.document where id = v_inv1;
  case_name := 'issuing it allocates the next number from the series inside the same transaction';
  passed := v_n1 = 'INV-' || lpad(v_before::text, 6, '0')
        and (select next_value from erp.numbering_rule where tenant_id = v_tenant and code = 'sales_invoice') = v_before + 1
        and exists (select 1 from erp.journal j where j.tenant_id = v_tenant and j.document_id = v_inv1 and j.status = 'posted');
  detail := format('%s became %s; series now %s; journal posted', v_draft, v_n1,
                   (select next_value from erp.numbering_rule where tenant_id = v_tenant and code = 'sales_invoice'));
  return next;

  -- 3. The next issue takes the next number.
  v_cases := v_cases + 1;
  v_inv2 := erp.open_document('sales_invoice', v_customer, v_e1, null, null, null, null);
  perform erp.add_document_line(v_inv2, v_item, 1, 5000, 'numbering at issue, second');
  perform erp.transition_document(v_inv2, 'issue', 'numbering suite');
  select document_number into v_n2 from erp.document where id = v_inv2;
  case_name := 'a second invoice issued takes the number after it';
  passed := v_n2 = 'INV-' || lpad((v_before + 1)::text, 6, '0');
  detail := format('%s then %s', v_n1, v_n2);
  return next;

  -- 4. A rolled-back issue leaves no gap.
  v_cases := v_cases + 1;
  v_n3 := null;
  begin
    v_inv3 := erp.open_document('sales_invoice', v_customer, v_e1, null, null, null, null);
    perform erp.add_document_line(v_inv3, v_item, 1, 5000, 'numbering at issue, rolled back');
    perform erp.transition_document(v_inv3, 'issue', 'numbering suite');
    select document_number into v_n3 from erp.document where id = v_inv3;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;
  v_inv4 := erp.open_document('sales_invoice', v_customer, v_e1, null, null, null, null);
  perform erp.add_document_line(v_inv4, v_item, 1, 5000, 'numbering at issue, after the rollback');
  perform erp.transition_document(v_inv4, 'issue', 'numbering suite');
  select document_number into v_n4 from erp.document where id = v_inv4;
  case_name := 'an issue that rolls back consumes nothing: the next invoice takes the same number';
  passed := v_n3 = 'INV-' || lpad((v_before + 2)::text, 6, '0') and v_n4 = v_n3;
  detail := format('rolled back after taking %s; the next issue took %s', v_n3, v_n4);
  return next;

  -- 5. A cancelled draft consumes nothing.
  v_cases := v_cases + 1;
  v_inv5 := erp.open_document('sales_invoice', v_customer, v_e1, null, null, null, null);
  perform erp.transition_document(v_inv5, 'cancel', 'numbering suite');
  select document_number into v_n5 from erp.document where id = v_inv5;
  select next_value into v_after from erp.numbering_rule where tenant_id = v_tenant and code = 'sales_invoice';
  case_name := 'a draft cancelled before issue keeps its provisional number and the series does not move';
  passed := v_n5 like 'DRAFT-%' and v_after = v_before + 3;
  detail := format('cancelled as %s; series at %s (three issued)', v_n5, v_after);
  return next;

  -- 6. The register's rule is green, and the gap report is empty.
  v_cases := v_cases + 1;
  v_out := erp.assert_documents_numbered();
  case_name := 'the numbering assertion passes: every committed invoice numbered, the gapless series intact';
  passed := v_out like 'document numbering: % committed document(s) numbered, 1 gapless rule(s)%'
        and not exists (select 1 from erp.sequence_gap_report() g where g.rule_code = 'sales_invoice');
  detail := v_out;
  return next;

  -- 7. A committed document left provisional is refused.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    update erp.document set document_number = 'DRAFT-STUCK0000' where id = v_inv1;
    begin
      perform erp.assert_documents_numbered();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'a committed document still carrying a provisional number is refused by name';
  passed := coalesce(v_msg like 'CLOVEERP_DOCUMENTS_UNNUMBERED:%' and v_msg like '%provisional number%', false);
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- 8. Undone.
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-issue')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000d5');
  detail := 'zz-issue rolled back with its invoices';
  return next;

  if v_cases <> 8 then
    raise exception 'CLOVEERP_SUITE_SHRANK: numbering_at_issue_suite ran % cases, expected 8', v_cases;
  end if;
end;
$$;

create or replace function erp_test.assert_numbering_at_issue_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_fail   integer;
  v_all    integer;
  v_detail text;
begin
  create temp table if not exists _numbering_at_issue on commit drop as
    select * from erp_test.numbering_at_issue_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _numbering_at_issue;
  drop table _numbering_at_issue;
  if v_fail > 0 then
    raise exception E'CLOVEERP_NUMBERING_AT_ISSUE_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 8 then
    raise exception 'CLOVEERP_SUITE_SHRANK: numbering_at_issue_suite ran % cases, expected 8', v_all;
  end if;
  return format('numbering at issue: %s/%s cases passed', v_all, v_all);
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_legislation_provenance();
select erp_test.assert_legislation_packs_suite();
select erp_test.assert_numbering_at_issue_suite();
select erp_test.assert_numbering_suite();
select erp_test.assert_companies_suite();
select erp_test.assert_onboarding_interview_suite();
select erp_test.assert_finance_suite();
select erp_test.assert_sales_suite();
select erp_test.assert_sales_depth_suite();
select erp_test.assert_demo_history_suite();
select erp.assert_whole_database_reconciles();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_configuration_promotable();
select erp.assert_packs_installable();
select erp.assert_part5_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_resource_coverage();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();

-- And the whole console, green.
do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
