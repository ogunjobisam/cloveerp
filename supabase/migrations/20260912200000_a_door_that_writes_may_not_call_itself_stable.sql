-- Ten doors that write, declared stable.
--
-- erp.assert_authorising_doors_are_volatile() found all ten on the first build
-- that ever reached the check catalogue:
--
--   a public door reaches erp.authorise(), which writes an access-log row, but
--   is declared stable, so PostgREST runs it in a read-only transaction and
--   the call fails
--
-- Every one of them arrived with the API keys, webhooks, finance statements
-- and document issue work. None had been run by a real caller: stable is a
-- promise to the planner that the function writes nothing, PostgREST believes
-- it and opens a read-only transaction, and the access-log insert inside
-- erp.authorise() then aborts the request. The reads would have failed in
-- production the first time somebody opened the screen.
--
-- Volatile is the default and the truth. Nothing else about these doors
-- changes: same body, same grants, same gate.
--
-- erp_test.assert_caller_reachable_internal_suite()'s eighth case reads the
-- same report over both writers, so it clears with them.

alter function public.erp_api_keys() volatile;
alter function public.erp_balance_sheet(date, text, text) volatile;
alter function public.erp_cost_centres() volatile;
alter function public.erp_document_issues(uuid, integer) volatile;
alter function public.erp_profit_and_loss(date, date, text, text) volatile;
alter function public.erp_sales_invoice_contract(uuid) volatile;
alter function public.erp_sales_invoice_issue_readiness(uuid) volatile;
alter function public.erp_trial_balance(date, date, text, text) volatile;
alter function public.erp_webhook_deliveries(uuid, integer) volatile;
alter function public.erp_webhook_subscriptions() volatile;

select erp.assert_authorising_doors_are_volatile();
