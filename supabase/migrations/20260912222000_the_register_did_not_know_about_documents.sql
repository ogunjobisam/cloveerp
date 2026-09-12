-- Two findings from erp.assert_part5_coverage(), both left by the same work.
--
--   a capability claims a function that does not exist
--     [5.7.statutory_reporting] public.erp_trial_balance()
--   a module has no registered capabilities
--     [document] Part 5 names this module and nothing claims to deliver any of it
--
-- The first is a signature that moved. 20260911005223 gave the trial balance a
-- period, a ledger and a cost centre; the register still claimed the no-argument
-- door it replaced, so it was pointing at a function that had stopped existing.
-- The register verifies by name and signature precisely so a change like that
-- cannot pass unnoticed, and it did not.
--
-- The second is a module registered with nothing behind it. 20260911090027
-- declared `document` and the coverage report refuses any module in
-- erp_ref.module with no capability claiming to deliver it — "a module that is
-- not written down is exactly the failure the register exists to prevent",
-- as 20260904640000 put it when the commercial module arrived the same way.
--
-- Registered under Part 15 rather than Part 5, for the same reason the
-- commercial module was registered under Part 17: the register is numbered from
-- Part 5 but the check is about modules, and document output is §15.1's
-- subject. The requirement below is the specification's sentence, not a
-- description of what was built.

update erp_ref.part5_capability
   set artefacts = array_replace(artefacts,
                                 'public.erp_trial_balance()',
                                 'public.erp_trial_balance(date,date,text,text)')
 where code = '5.7.statutory_reporting'
   and 'public.erp_trial_balance()' = any (artefacts);

insert into erp_ref.part5_capability
  (code, section, section_name, module_code, requirement, artefacts, status, gap)
values
('15.1.document_issue', '15.1', 'The output subsystem', 'document',
 'Every rendered output is archived and retrievable by its document reference, and its template version recorded so a document can always be reproduced exactly as issued',
 array['erp.document_sequence', 'erp.document_issue', 'erp.document_preview',
       'erp.document_reprint', 'erp.output_template', 'erp.output_template_version',
       'erp.sales_invoice_contract(uuid)', 'erp.validate_sales_invoice_issue(uuid)',
       'erp.issue_sales_invoice(uuid,uuid,uuid)',
       'erp.complete_document_issue(uuid,text,text)',
       'erp.void_document_issue(uuid,text)', 'erp.amend_sales_invoice(uuid,text)',
       'erp.reprint_document_issue(uuid,text)', 'erp.mark_document_issue_sent(uuid)'],
 'built', null)
on conflict (code) do update set
  section = excluded.section, section_name = excluded.section_name,
  module_code = excluded.module_code, requirement = excluded.requirement,
  artefacts = excluded.artefacts, status = excluded.status, gap = excluded.gap;

select erp.assert_part5_coverage();
