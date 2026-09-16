-- A step points at what comes next.
--
-- A purchase order sent to its supplier had been worked: everything the
-- purchase order step does to an order had been done to it. The panel said
-- "Nothing on this step applies to this record in its current state." and
-- stopped there, which reads as a fault rather than as progress — the record
-- has not stuck, it has moved on, and nothing on the screen said where to.
--
-- The panel now names the step that follows and offers the way to it. Both
-- words are said with the step's own name after them, so both are words an
-- organisation renames rather than words the code owns: a deployment that calls
-- its steps stages says "The next stage is Goods receipt", and the button
-- follows it.
--
-- No behaviour here. Two rows in the dictionary, so that
-- supabase/ci/screen_strings.sh finds a row for every string the app says and
-- erp.terminology_alignment_report() can see them.

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('The next step is', 'Said on a step that has nothing left to do for the record chosen on it, before the name of the step that follows it in the chain.'),
    ('Go to', 'The button beside that sentence, before the name of the step that follows it.')
) as v(text, why)
on conflict (key, locale) do nothing;

do $words$
declare v_missing text;
begin
  select string_agg(quote_literal(t.text), ', ' order by t.text) into v_missing
    from (values ('The next step is'), ('Go to')) as t(text)
   where not exists (select 1 from erp_ref.resource r
                      where r.key = erp_ref.ui_key(t.text) and r.locale = 'en');
  if v_missing is not null then
    raise exception 'CLOVEERP_SCREEN_WORDS_MISSING: % have no en row', v_missing;
  end if;
end
$words$;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_vocabulary_aligned();
select erp.assert_resource_coverage('en');
