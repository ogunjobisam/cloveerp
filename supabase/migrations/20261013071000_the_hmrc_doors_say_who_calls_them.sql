-- The HMRC doors say who calls them.
--
-- A follow-up to 20261013070000, found by supabase/ci/preflight.sh (rule F):
-- six doors are called by supabase/functions/hmrc and named by no screen —
-- five with the service key, and the one that opens a ticket with the
-- person's own session — so the build's check that every door has a home
-- would refuse them. They are registered as the integration's.

insert into erp_meta.api_only_door (function_name, caller, intended_screen_path, reason) values
  ('erp_hmrc_open_ticket', 'integration', null,
   'Called by the hmrc Edge Function with the person''s own session when they press Connect, Read obligations or Submit on the VAT screen, so the database decides as them.'),
  ('erp_hmrc_ticket', 'integration', null,
   'Read by the hmrc Edge Function, with the service key, under a ticket the person''s own call to erp_hmrc_open_ticket opened on the VAT screen.'),
  ('erp_hmrc_store_tokens', 'integration', null,
   'Called by the hmrc Edge Function to keep the tokens HMRC gave a company, in Vault, when it connects or refreshes.'),
  ('erp_hmrc_record_obligations', 'integration', null,
   'Called by the hmrc Edge Function to record the VAT obligations HMRC holds, with their period keys.'),
  ('erp_hmrc_record_submission', 'integration', null,
   'Called by the hmrc Edge Function to record a VAT return submitted to HMRC, with HMRC''s receipt.'),
  ('erp_hmrc_close_ticket', 'integration', null,
   'Called by the hmrc Edge Function to close a reading ticket when HMRC answers with nothing to record.')
on conflict (function_name) do nothing;
