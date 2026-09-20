-- =============================================================================
-- The enquiry notification address is not seeded, and this repairs the file
-- that said it was.
--
-- 20260920500000 was pushed seeding erp_meta.platform_setting with
-- enquiry.notify_to = ["sales@cloveerp.com"], and the build refused it: with an
-- address set, erp.enquiry_recipients() stops reaching the platform owners, and
-- two suites say in so many words that it should.
--
--   erp_test.enquiry_suite   "an owner is told and a support account is not"
--   erp_test.ingress_suite   "the ingress can find who to tell, and only that"
--
-- Both are right, and both are in migrations already pushed. "The owners are
-- told" is exactly what this schema does when nobody has said otherwise, and
-- the seed was buying one fewer visit to a screen that same migration adds, at
-- the price of making two true assertions false.
--
-- The seed was then taken out of 20260920500000 by editing it, which is the one
-- thing a migration may not have done to it — see supabase/ci/migrations_edited.txt
-- and the rule it enforces. An edit reaches no environment that has already run
-- the file, and a build from an empty cluster only ever sees the edited
-- version, so the two disagree in silence. This migration is the repair that
-- register names: it makes an environment which ran the first version end up
-- where one running the second starts.
--
-- ── WHAT IT UNDOES, AND WHAT IT IS CAREFUL NOT TO ────────────────────────────
--
-- Only the seed. The row is matched on the exact value that migration wrote AND
-- on updated_by being null, which erp_meta.platform_setting.updated_by defines
-- as "the row a migration wrote" — an address a platform owner has since set
-- from the console carries their staff id and is left exactly as it is. A
-- repair that could quietly delete somebody's setting is worse than the fault
-- it repairs.
--
-- On a build from an empty cluster there is no such row and this deletes
-- nothing, which is the point: both routes arrive at "no address set, the
-- owners are told", and an owner sets the address from Platform -> Enquiries
-- when they want it moved.
-- =============================================================================

delete from erp_meta.platform_setting
 where key = 'enquiry.notify_to'
   and value = '["sales@cloveerp.com"]'::jsonb
   and updated_by is null;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Nothing here defines a function, a table or a policy, so the generators have
-- nothing new to reach; they are re-run because every migration re-runs them
-- and one that quietly does not is the migration nobody can reason about. The
-- assertions are the two cheap structural ones, for the same reason.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
