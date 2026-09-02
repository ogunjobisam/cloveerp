-- ─────────────────────────────────────────────────────────────────────────────
-- The commercial module's capabilities, registered where the coverage
-- assertion reads them.
--
-- 20260904590000 declared a module, `commercial`, and erp.assert_part5_coverage()
-- fails any module in erp_ref.module with no row in erp_ref.part5_capability:
-- "Part 5 names this module and nothing claims to deliver any of it". The
-- register was written for Part 5 and its sections are numbered from it, but
-- the check is about modules, and a module that is not written down is
-- exactly the failure the register exists to prevent. So the seven sections
-- of v1.5 Part 17 that the module delivers are registered here, each naming
-- the tables and routines that carry it, all of which the report verifies
-- exist by name and signature.
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.part5_capability
  (code, section, section_name, module_code, requirement, artefacts, status, gap)
values
('17.5.platform_organisation', '17.5', 'The platform as an organisation', 'commercial',
 'One organisation on the deployment is the platform itself, designated once by an owner; its products, quotations, approval chains and output templates are the commercial process (D37)',
 array['erp_meta.platform_organisation', 'erp.designate_platform_organisation(text,text)',
       'erp.is_platform_organisation(uuid)', 'erp.require_platform_organisation()'],
 'built', null),
('17.6.price_book', '17.6', 'Price book and rate cards', 'commercial',
 'The price book as a configuration object with versions in force; price items by kind with rates per term and currency; a cost model behind each; legislation packs priced at nil by default',
 array['erp.price_item', 'erp.cost_model', 'erp.open_price_book(text,text,text[],date,text)',
       'erp.set_rate(text,text,character,bigint,text)', 'erp.set_cost_model(text,character,bigint,bigint,bigint,text)',
       'erp.price_book_report()'],
 'built', null),
('17.7.quote_builder', '17.7', 'Quote and pricing builder', 'commercial',
 'A quote assembled from price items on the document spine, margin visible live per line and in total (D36), discount beyond the threshold routed through the approval engine, every version retained, the order form rendered through the output subsystem',
 array['erp.commercial_quote', 'erp.open_commercial_quote(text,text,text,text,integer,character,integer,text,text)',
       'erp.add_quote_line(uuid,text,numeric,numeric)', 'erp.quote_margin(uuid)', 'erp.submit_quote(uuid)',
       'erp.issue_quote(uuid)', 'erp.revise_quote(uuid,text)', 'erp.expire_commercial_quotes()',
       'erp.commercial_quote_detail(uuid)'],
 'built', null),
('17.8.contract_record', '17.8', 'The contract record', 'commercial',
 'A contract created from an accepted quote with structured terms, documents with checksums and signatures, amendments with their own signatures, and key dates that raise notifications at their lead time',
 array['erp_meta.contract', 'erp_meta.contract_document', 'erp_meta.contract_amendment', 'erp_meta.contract_notice',
       'erp.create_contract_from_quote(uuid,text,text,text,date,integer,text,integer,text,text,jsonb,jsonb,date,integer)',
       'erp.sign_contract(uuid,text,text,text)', 'erp.amend_contract(uuid,text,date,jsonb,text)',
       'erp.raise_contract_key_dates()', 'erp.contract_position(uuid)'],
 'built', null),
('17.9.contract_provisions_entitlement', '17.9', 'The contract provisions the entitlement', 'commercial',
 'A signed contract or amendment provisions the subscription, the entitlement bands and the features directly; nothing an organisation is entitled to differs from what was sold without a recorded amendment (D35)',
 array['erp_meta.contract_entitlement', 'erp_meta.contract_capability',
       'erp.provision_entitlement_from_contract(uuid)', 'erp.assert_contract_provisions_entitlement()'],
 'built', null),
('17.10.renewal_and_revenue', '17.10', 'Renewal, invoicing and revenue', 'commercial',
 'Renewals proposed at the lead time with the uplift rule applied and quoted through the same builder; invoice schedules from the term reconciled against metering with overage priced from the book; revenue, margin, renewal rate, churn and revenue at risk from the contract register',
 array['erp_meta.renewal', 'erp_meta.contract_invoice', 'erp_meta.index_rate', 'erp.uplift_pct_for(jsonb,date)',
       'erp.propose_renewals()', 'erp.open_renewal_quote(uuid)', 'erp.renew_contract(uuid,text,text,text)',
       'erp.expire_contracts()', 'erp.generate_invoice_schedule(uuid)', 'erp.invoice_overage_lines(uuid)',
       'erp.issue_contract_invoice(uuid)', 'erp.revenue_report()'],
 'built', null),
('17.11.customer_sees_own_agreement', '17.11', 'What the customer sees', 'commercial',
 'The organisation sees its own contract, documents, entitlement, live usage, invoices with the metering behind them, notice deadline, uplift rule and sub-processors without asking (D38)',
 array['erp.my_agreement()', 'erp.my_contract_document(uuid)', 'erp.assert_customer_view_sound()'],
 'built', null)
on conflict (code) do update set
  section = excluded.section, section_name = excluded.section_name, module_code = excluded.module_code,
  requirement = excluded.requirement, artefacts = excluded.artefacts, status = excluded.status, gap = excluded.gap;

select erp.assert_part5_coverage();
