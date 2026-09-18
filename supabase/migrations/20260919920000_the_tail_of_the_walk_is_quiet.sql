set lock_timeout = '30s';

-- =============================================================================
-- 20260919920000  The tail of the walk is quiet
-- -----------------------------------------------------------------------------
-- The owner, on the product's own selling point: "One area I still find
-- confusing is the UI — too much on the screens."
--
-- 20260919900000 took /procurement, /sales and the document record. It did not
-- take the rest of the demonstration, and e2e/demo-path.ts says where the rest
-- of the demonstration is: both flows share a five-step tail, and four of the
-- screens on this change are in it. This file seeds the words those four now
-- say. Nothing else here writes to the database — but a word on a screen is a
-- glossary row a tenant can change, supabase/ci/screen_strings.sh fails the
-- build for a screen string with no en resource row, and
-- erp.terminology_alignment_report() cannot show drift over a string it cannot
-- see.
--
-- What the four screens did, for the record, since the words below are the
-- words they say:
--
--   * /inventory drew two tables, Count tasks and Warehouse tasks, reading
--     erp_count_tasks and erp_warehouse_tasks — the same two doors the Count
--     and Put away steps of its own chain list, one screenful higher, with
--     search, paging and Show finished, and a panel beside them showing every
--     column of the chosen row rather than the six a table had room for. Both
--     tables are gone. Expiry horizon is no step's list and stays.
--
--   * /logistics drew one, Shipments, reading erp_shipments: the only door the
--     module has, and the list three of its four steps already draw. Gone, and
--     the module has no worklist at all now, which is the honest answer for a
--     module whose every record is on its chain.
--
--   * /operations/assurance is the last screen both flows reach, and it drew
--     every structural check in erp_meta.diagnostic_check as a row of a table
--     — a hundred and some check names with a pill each. The reader's question
--     was never what the checks are; it was whether everything reconciles. The
--     verdict is now a sentence, a failing check is drawn in full with the
--     code to quote, and the register is behind "Show every check" with its
--     count on the button. Nothing is dropped.
--
--   * / said who you are and where you are working and never what a person
--     does there. It now says it, in one line, above the organisation and
--     scope it already carried.
--
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The words on the screen
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Fourteen. Twelve of them supabase/ci/screen_strings.sh demands; two it
-- cannot see, because its ui("…") harvest is line-based and those two are long
-- enough that the formatter puts the literal on its own line. They are seeded
-- anyway — the register's reach is the point, not the script's — and the gap
-- is written down here rather than quietly worked around: it is why
-- "Plan, source, make, move, sell, settle…" on the launchpad has had no row
-- since it was written, and closing it is a change to the script and a
-- migration seeding every existing multi-line string, which is not this.

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string on the tail of the demonstration path, rendered through ui(). ' || v.why
  from (values
    -- /inventory
    ('Knowing what is on the shelf, what it is worth, and putting right where the shelf and the ledger disagree.',
     'The Stock module''s own sentence, under its title and on its tile. It replaces a list of five report names ending in how they are computed.'),
    -- /logistics
    ('Getting what has been picked out of the door and proving it arrived, with the carrier''s cost landing on the stock it carried.',
     'The Despatch module''s own sentence. It replaces three nouns and keeps the one fact the nouns carried, that booking a shipment lands freight on stock.'),
    -- /operations/assurance
    ('Everything reconciles.',
     'The verdict when every check ran and every one held.'),
    ('Everything that could run reconciles.',
     'The verdict when everything that ran held but some checks could not run, because claiming everything reconciles would be a claim about a check nobody made.'),
    ('One check does not hold.',
     'The verdict on a single failure, which is the failure a person actually meets.'),
    ('{count} checks do not hold.',
     'The verdict on more than one. Two whole sentences rather than one with a plural rule in it, because a translator handed a fragment and a number cannot put either right.'),
    ('{count} checks held against this database.',
     'The count under the verdict, said whichever way the verdict went.'),
    ('{count} need an organisation and were not run, because this session is not inside one.',
     'Said after it when erp_platform_assurance() reports ok as null for a tenant-scoped check, which is neither a pass nor a failure.'),
    ('Every one of these fails the build rather than warning, so a check that does not hold on a live database is something to report rather than something to work around. Quote the code under it: it names exactly what was compared and what was found.',
     'What to do about a failure, said only where there is one. It used to be in the page header, where it was advice about nothing.'),
    ('Show every check',
     'The fold over the register itself, which is a hundred and some rows and is not the question.'),
    ('Hide the checks',
     'The same control, once it is open.'),
    ('Holds', 'The result pill on a check that passed. Raw text until now, and so unrenameable.'),
    ('Violated', 'The result pill on a check that failed.'),
    ('Needs an organisation',
     'The result pill on a check that could not run for want of one.'),
    -- /
    ('Anything waiting on your decision, then the way into every screen you may open.',
     'What the desk''s home is for, said under the greeting. It said only which organisation, company and site you were in, which is where you are rather than what you do; that line is still there, under this one.')
) as v(text, why)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Nothing above creates a routine, a table or a policy, so the generators have
-- nothing to find. They run because every migration ends by running them, and
-- a migration that skips them is the one that leaves a gap.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_resource_coverage('en');
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_no_dead_configuration();
