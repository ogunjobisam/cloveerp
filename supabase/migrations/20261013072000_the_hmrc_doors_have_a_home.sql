-- The HMRC doors have a home.
--
-- 20261013071000 registered the six doors supabase/functions/hmrc calls as
-- API-only, because supabase/ci/preflight.sh (rule F) read only src for the
-- doors the application names. The build's own check, supabase/ci/app_doors.sh,
-- has read supabase/functions as well since 8 October, so the doors have a
-- home there and the rows are refused as kept past their reason. They go; rule
-- F now reads supabase/functions too.

delete from erp_meta.api_only_door
 where function_name in ('erp_hmrc_open_ticket', 'erp_hmrc_ticket', 'erp_hmrc_store_tokens',
                         'erp_hmrc_record_obligations', 'erp_hmrc_record_submission', 'erp_hmrc_close_ticket')
   and caller = 'integration';
