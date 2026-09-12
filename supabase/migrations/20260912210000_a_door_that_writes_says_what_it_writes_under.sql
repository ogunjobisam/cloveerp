-- My mistake, and the half of it I left out.
--
-- 20260912200000 made ten doors volatile because they reach erp.authorise(),
-- which writes. That was right, and erp.assert_authorising_doors_are_volatile()
-- went green. It was also incomplete: erp.public_api_report() reads the same
-- column and draws the opposite conclusion from it —
--
--   a public API function writes but is not on the write allow-list
--   it is VOLATILE, so it may write; add it to
--   erp_meta.public_write_allowance with a rationale, or make it STABLE
--
-- — so the ten findings moved from one assertion to another and the live
-- deploy caught it. Declaring that a door writes and never saying what it
-- writes under is not a fix, it is the same gap under a different name. The
-- register is where a door says which gate stands in front of it, and every
-- one of these ten calls erp.authorise() in its own body, so the gate is
-- named honestly rather than inferred through a delegate.
--
-- What each of them actually writes is one access-log row, raised by
-- erp.authorise() as the record that somebody read this. That is the whole of
-- their writing, and it is the reason they cannot be stable.
--
-- I should have run erp.assert_public_api_safe() at the end of 20260912200000.
-- The house convention ends a migration with the generators and that assertion
-- for exactly this reason, and I skipped it to save a minute of replay.

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_api_keys', 'erp.authorise',
   'Lists the organisation''s API keys under administration.integrate. Writes only the access-log row erp.authorise() raises.'),
  ('erp_webhook_subscriptions', 'erp.authorise',
   'Lists webhook subscriptions under administration.integrate. Writes only the access-log row erp.authorise() raises.'),
  ('erp_webhook_deliveries', 'erp.authorise',
   'Lists delivery attempts for a subscription under administration.integrate. Writes only the access-log row erp.authorise() raises.'),
  ('erp_trial_balance', 'erp.authorise',
   'Reads the trial balance under finance.read. Writes only the access-log row erp.authorise() raises.'),
  ('erp_profit_and_loss', 'erp.authorise',
   'Reads the profit and loss under finance.read. Writes only the access-log row erp.authorise() raises.'),
  ('erp_balance_sheet', 'erp.authorise',
   'Reads the balance sheet under finance.read. Writes only the access-log row erp.authorise() raises.'),
  ('erp_cost_centres', 'erp.authorise',
   'Lists cost centres under finance.read. Writes only the access-log row erp.authorise() raises.'),
  ('erp_document_issues', 'erp.authorise',
   'Lists what has been issued against a document under document.reprint. Writes only the access-log row erp.authorise() raises.'),
  ('erp_sales_invoice_contract', 'erp.authorise',
   'Returns the contract a sales invoice would be issued against, under document.issue. Writes only the access-log row erp.authorise() raises.'),
  ('erp_sales_invoice_issue_readiness', 'erp.authorise',
   'Reports whether a sales invoice can be issued, under document.issue. Writes only the access-log row erp.authorise() raises.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
