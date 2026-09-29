-- =============================================================================
-- 20260927220223 — Open counts come first in the count-task door
--
-- Written by Lovable (41be47fb) and applied to production on 27 September.
-- It restated public.erp_count_tasks so open counts sort first, and it sorts
-- before 20260927400000 and 20260928100000, the two migrations that built the
-- door it restated: a database built from nothing reached it before its door
-- existed, and the replay stopped. Its version stays, because production has
-- recorded it.
--
-- Its restatement moved, unchanged, to
-- 20261001900000_the_count_task_door_puts_open_counts_first.sql, which runs
-- after its door exists and proves the door governed in its own transaction.
-- Reduced to this note with the owner's leave on 29 September, and registered
-- in supabase/ci/migrations_edited.txt against that migration.
-- =============================================================================

select 1;
