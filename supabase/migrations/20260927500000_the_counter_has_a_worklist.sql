set lock_timeout = '30s';

-- =============================================================================
-- 20260927500000  The counter has a worklist
-- -----------------------------------------------------------------------------
-- PR10, M3b: the screen half of node I2 of docs/spec/simplification-review.md,
-- "the counter's worklist", on top of M3a (20260927400000), which made
-- public.erp_count_tasks say where each count task stands.
--
-- ── WHAT CHANGES, AND WHERE ──────────────────────────────────────────────────
--
-- The screen is src/components/erp/count-worklist.tsx, on /inventory/audit:
--   * every place waiting to be counted, sheet by sheet in the order of the
--     paper, with one box and one Record press each, and Enter moving to the
--     next place;
--   * the counts that wait on somebody: held for somebody to post and why,
--     agreed by an approver, outside tolerance with nobody to approve it,
--     refused, or with the approver; each with only the verbs its door
--     accepts (Post, Count it again, Cancel with a reason), and Post not
--     drawn where the door would refuse the reader for having counted it
--     (post_refused_to_me);
--   * Print on each sheet, which renders the sheet through
--     public.erp_render_count_sheet and prints its blocks.
-- Record a count, Count it again and Confirm a count leave the screen's action
-- bar: the rows carry them with the count already chosen.
--
-- This migration is what the screen needs of the database, and only that:
--   * the two erp_meta.api_only_door rows that held erp_cancel_count_task and
--     erp_render_count_sheet as pending_screen for /inventory/audit are
--     deleted, because the screen now names both doors.
--     erp.assert_doors_have_a_home() refuses the screen without the deletion
--     and the deletion without the screen, so they land together;
--   * the words the screen says, seeded in English so each can be renamed.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * No door changes. erp_count_tasks keeps the signature M3a kept, and the
--     site filter is the screen's, as the balance panels' is. The help topic
--     for /inventory/audit already carries both doors (20260927000000,
--     20260927100000).
--   * No new refusal, table, lifecycle, change set or register restatement.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The two doors have a home
-- ─────────────────────────────────────────────────────────────────────────────

do $home$
declare
  v_n integer;
begin
  delete from erp_meta.api_only_door d
   where d.function_name in ('erp_cancel_count_task', 'erp_render_count_sheet')
     and d.caller = 'pending_screen'
     and d.intended_screen_path = '/inventory/audit';
  get diagnostics v_n = row_count;
  if v_n <> 2 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: expected the two pending_screen rows for /inventory/audit, deleted %', v_n;
  end if;
end
$home$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The words the worklist says
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). The counter''s worklist on the Counting screen (20260927500000).'
  from (values
    ('Agreed'),
    ('Agreed by its approver.'),
    ('Cancelled'),
    ('Counts that did not post as they were recorded: held for somebody to post, agreed by an approver, outside their tolerance, refused, or with their approver. Each says why, and offers only what can be done with it.'),
    ('Counts that wait on somebody'),
    ('Counts to record'),
    ('Every place waiting to be counted, sheet by sheet in the order of the paper. Type what you found and press Enter: the figure is recorded and the next place is ready. A count inside its tolerance posts as it is recorded.'),
    ('Held for somebody to post.'),
    ('Inside its tolerance on its own, but with what the system has already posted at this place it is outside it, so a person posts it.'),
    ('It was to post as it was recorded, and the post was refused. The figure is kept for somebody to post.'),
    ('No sheet'),
    ('Nothing is waiting on anybody. Every count recorded has posted, or is still to be counted above.'),
    ('Nothing is waiting to be counted. Raise count tasks from a counting programme, and each place to count is listed here in the order of its sheet.'),
    ('Only the first 500 counts are listed, open work first. Counts past them are not shown here.'),
    ('Open the counting worklist'),
    ('Outside its tolerance'),
    ('Post'),
    ('Posted as it was recorded'),
    ('Raise tasks from a counting programme, then record each place on the worklist below. A count outside its tolerance is decided here by its approver.'),
    ('Record the count'),
    ('Refused by its approver.'),
    ('Send a count back to be counted: one its approver refused, or one counted outside its tolerance with nobody to approve it. The expected figure is re-read from the records as they stand now.'),
    ('The site''s count posting policy holds a count inside its tolerance for somebody to post.'),
    ('The site''s count posting policy holds the counter''s own count for somebody else to post.'),
    ('To count'),
    ('Waiting for its approver.'),
    ('What can be done'),
    ('With its approver'),
    ('You counted this, so somebody else posts it.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
