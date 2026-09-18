set lock_timeout = '30s';

-- =============================================================================
-- 20260919900000  A screen says what it is for
-- -----------------------------------------------------------------------------
-- The owner, on the product's own selling point: "One area I still find
-- confusing is the UI — too much on the screens."
--
-- The example was Receive this order. It opened holding a purchase-order
-- picker, a four-column line editor, an Add a line button, a hint of three
-- sentences and a refusal in red, and the order-line picker said:
--
--     Nothing to choose from yet — this list is empty for this organisation.
--
-- That sentence was false. The picker reads erp_receivable_lines(p_order_id),
-- which is scoped to the order and to nothing else; the organisation had
-- hundreds of order lines. The true answer — that this order already had a
-- goods receipt holding every line — was in the refusal further down the page,
-- after the form had been filled in and pressed.
--
-- So the rule the screens now follow, and the reason there is a migration for
-- what is otherwise a change to four files of TypeScript:
--
--   A picker that follows another choice is never empty *for the
--   organisation*. It is empty for the record chosen above it, and it says so
--   — in the door's own words where they are declared, and in the general form
--   otherwise. Only a picker that follows nothing may blame the organisation,
--   because for that one it is true.
--
-- Every one of those sentences is a word on a screen, and this product's
-- premise is that a word on a screen is a glossary row a tenant can change.
-- supabase/ci/screen_strings.sh fails the build for a screen string with no en
-- resource row, and erp.terminology_alignment_report() cannot show drift over a
-- string it cannot see. This file seeds the eleven.
--
-- Four of the eleven are not new sentences but newly renameable ones: the two
-- picker notes and the two states of a line editor's Add a line button were
-- literal JSX text, rendered raw, invisible to the register. They now go
-- through ui() like everything else.
--
-- The rest of the change writes nothing to the database. For the record, since
-- the words seeded here are the words those screens say:
--
--   * /procurement's action bar held all twenty of the module's verbs under a
--     heading that named three of them. Thirteen are steps of the strip above
--     it, which offers each with the record already chosen. The bar now holds
--     the seven that are nowhere else — unstagedActions(), which ModulePage has
--     used since it was written and these two hand-written screens did not —
--     under a heading that describes them. /sales the same: nine verbs became
--     four, four of the five being steps of its own strip and the fifth a
--     second "create a delivery" with the order not yet chosen.
--   * Both screens then listed, in four tables each, the same documents the
--     strip lists at the step they belong to. The tables are gone.
--   * A line editor fed by a door no longer offers Add a line before that door
--     has answered, or after it has answered with nothing: a row added there
--     is pickers that are all empty and a refusal at the end of it.
--
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The words on the screen
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string on the buying and selling screens, rendered through ui(). ' || v.why
  from (values
    ('This order has nothing left to receive: every line has been received in full, or is already on a goods receipt that has not been cancelled.',
     'Said by the order-line picker on Receive this order when it offers nothing. It is what erp_receivable_lines answering with no row actually means, and it replaces a sentence that blamed the organisation.'),
    ('This order has nothing left to deliver: every line has been delivered in full, or is already on a delivery that has not been cancelled.',
     'The same sentence for erp_deliverable_lines, on Create a delivery from this order.'),
    ('Nothing to choose from here, because of what was chosen above.',
     'Said by any other picker that follows a choice and has no sentence of its own. It replaces the organisation-level one, which cannot be true of a list scoped to a record.'),
    ('Nothing to choose from yet — this list is empty for this organisation.',
     'Said by a picker that follows nothing, which is the only kind of picker this is true of. Raw text until now, and so unrenameable.'),
    ('Make the choice above first.',
     'Said by a picker, and by a line editor''s Add a line button, while the choice it follows has not been made.'),
    ('Reading what is left.',
     'Said by Add a line while the door that fills the editor is still answering.'),
    ('There is nothing left here to add a line for.',
     'Said by Add a line when that door answered with nothing, because every picker in a new row would be empty.'),
    ('The rest of buying',
     'The heading over the buying verbs that are not a step of the chain above them. It used to say Goods-in, matching and qualification over all twenty verbs, thirteen of which the chain carries.'),
    ('Work that sits beside the chain above rather than on it: match exceptions, blanket call-offs, drop-ships, approval routing by value, price lookups, supplier qualification and landed cost.',
     'Said under that heading, naming what the card holds so a reader knows whether their thing is in it.'),
    ('The rest of selling',
     'The same heading on the selling screen.'),
    ('Work that sits beside the chain above rather than on it: stock reservations, credit limits and holds, and customer returns.',
     'Said under that heading, for the same reason.')
) as v(text, why)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Nothing here creates a routine, a table or a policy, so the generators have
-- nothing to find; they run because every migration ends by running them and a
-- migration that skips them is the one that leaves a gap.

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
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_isolation();
