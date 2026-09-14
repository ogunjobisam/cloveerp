-- Each step shows what sits there.
--
-- Walking the demonstration organisation's Purchasing screen on 14 September,
-- the process strip — the screen a customer works from every day — said four
-- things it should not have:
--
--   1. A step listed every document of its type. "1 Requisition (26)" listed
--      requisitions already Ordered, and "2 Approval (26)" listed the same
--      twenty-six. A step now names the states a record waits there in, a
--      document step asks public.erp_documents for them (p_states,
--      20260914050000), the count on the step counts the same rows, and
--      "Show finished" brings the finished ones back as history.
--   2. The record beside the list printed the read's columns under their own
--      names: STATE ordered, TOTAL MINOR 317100, IS CANCELLED false. It now
--      shows a document's number and state, its customer or supplier, its
--      dates, its total as money and its first lines, and opens the document.
--   3. "Submit for approval" was offered on an Ordered requisition, and a
--      draft purchase order offered nothing that could move it on. A verb that
--      performs a transition is now offered only when the document's current
--      state has it, as public.erp_available_transitions says; a verb that is
--      not a transition only in the states it applies to; and the document's
--      other moves are offered beside them, as the document's own page offers
--      them. The database refuses what it always refused; the screen stops
--      offering it, and starts offering what can be done.
--   4. "GRNI value 400,552" had no currency and did not say what unit it was
--      in, and "Overdue 60+" read a column erp.receivables_ageing never had.
--      Money on a tile is now whole units with the currency's symbol, and the
--      overdue figure adds the two bands past sixty days.
--
-- And the help sheet named the screen by its route ("/procurement") and told
-- a customer to write "the terminology override help.local.procurement". It
-- names the screen as the menu does and says where the note is written.
--
-- All of that is the desk's business and changed in the desk. What is held
-- here is words: every string the desk now shows has a row it can be renamed
-- by, keyed erp_ref.ui_key(text), as supabase/ci/screen_strings.sh demands.
-- One of them is Stock's goods-in step, which listed every goods receipt ever
-- raised and now lists the stock standing in goods-in, as Purchasing's does.
--
-- Nothing here creates, changes or grants a function.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The words on the screens
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    -- The process strip: what sits at a step, and the record beside it.
    ('Show finished',
     'A process step: also list the records that have finished there, as history.'),
    ('Open the document',
     'A process step: open the chosen document on its own page.'),
    ('Document date',
     'A process step''s record: the date a document carries.'),
    ('More lines are on the document.',
     'A process step''s record: shown under the first lines of a longer document.'),
    ('Nothing on this step applies to this record in its current state.',
     'A process step''s record: none of the step''s verbs applies to the state the record is in.'),
    -- Stock's goods-in step, which now lists the stock standing there.
    ('Stock appears here once a receipt against a purchase order is posted.',
     'The goods-in step on Stock: said when nothing is standing in goods-in.'),
    -- A money tile.
    ('on hand, at cost',
     'The Stock value tile: what the figure is.'),
    -- The help sheet.
    ('The product''s guidance for {screen}. The same for every organisation; a note of your own sits beneath it.',
     'The help sheet: its opening sentence. {screen} is the screen''s name as the menu shows it.'),
    ('this screen',
     'The help sheet: the screen''s name, for a screen the menu does not name.'),
    ('Your organisation has not added a note for this screen. An administrator can add one under Terminology.',
     'The help sheet: said when the organisation has written no note of its own for the screen.')
) as v(text, why)
on conflict (key, locale) do nothing;

-- A row that did not land is a string the terminology screen cannot offer, and
-- the build would find out a step later with less to say about why.
do $words$
declare v_missing text;
begin
  select string_agg(quote_literal(t.text), ', ' order by t.text) into v_missing
    from (values
      ('Show finished'),
      ('Open the document'),
      ('Document date'),
      ('More lines are on the document.'),
      ('Nothing on this step applies to this record in its current state.'),
      ('Stock appears here once a receipt against a purchase order is posted.'),
      ('on hand, at cost'),
      ('The product''s guidance for {screen}. The same for every organisation; a note of your own sits beneath it.'),
      ('this screen'),
      ('Your organisation has not added a note for this screen. An administrator can add one under Terminology.')
    ) as t(text)
   where not exists (select 1 from erp_ref.resource r
                      where r.key = erp_ref.ui_key(t.text) and r.locale = 'en');
  if v_missing is not null then
    raise exception 'CLOVEERP_SCREEN_STRINGS_SHORT: no resource row for %', v_missing
      using hint = 'Row security refused the write, or erp_ref.ui_key changed. Seed the row the desk asks for.';
  end if;
end
$words$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();

select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_session_context_hygiene();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
