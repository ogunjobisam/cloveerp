set lock_timeout = '30s';

-- =============================================================================
-- 20260920160000  A control says what it is
-- -----------------------------------------------------------------------------
-- The accessibility pass of 18 September gave the step strip a name a screen
-- reader can use — "Requisition, step 1 of 8, 0 outstanding", where the tree
-- used to report the step's whole hint cut off mid-word — and gave every form a
-- way to say what is missing when Create is pressed, where it used to leave a
-- faint focus ring on one field and say nothing.
--
-- Six new sentences on screens, each rendered through ui(), so each gets the row
-- an organisation renames it by and supabase/ci/screen_strings.sh looks for.
-- They are whole sentences with placeholders rather than words stitched
-- together, so a translation can put them in its own order.
-- =============================================================================

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text, 'A screen string, rendered through ui(). ' || v.why
  from (values
    ('Add at least one line.', 'Under a line editor when Create was pressed with no lines.'),
    ('Nothing has been created yet. Fill in {fields} first.', 'At the top of a form when Create was pressed with required answers missing; {fields} is their labels.'),
    ('{field} is needed.', 'Under a required field left empty when Create was pressed.'),
    ('{step}, step {n} of {total}, not counted here', 'What a screen reader says for a step that keeps no list of its own.'),
    ('{step}, step {n} of {total}, still counting', 'What a screen reader says for a step whose count has not arrived.'),
    ('{step}, step {n} of {total}, {count} outstanding', 'What a screen reader says for a step: its name, where it is in the chain, and how much is waiting.')
  ) as v(text, why)
on conflict (key, locale) do nothing;

select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
