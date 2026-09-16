-- Approvals are easy to see.
--
-- My approvals has existed as long as approvals have, on the governance
-- screen, which is where a person goes when they already know the word
-- "governance". A buyer whose order is held and a manager asked about a
-- discount do not: they think "somebody said this needs approving", and they
-- look at the screen they are already on. So the count now travels to them —
-- the header carries it on every screen, and Home carries it as a card — and
-- both are one link back to the panel that was always there. Nothing new
-- decides an approval; a second place to decide would be a second place for
-- the wording and the refusals to drift.
--
-- The history that answers "what was approved, and by whom" was surfaced only
-- on the administrator's organisation screen. The same door is now read beside
-- My approvals as well, so the question and its answer are on one screen. The
-- administrator's copy stays where it is.
--
-- And the empty state said "Requests appear here when an approval band routes
-- one to you". An approval band is a row in a table we wrote; it is not a
-- thing a manager has ever had to know about. It now says what happens instead
-- of naming the mechanism that makes it happen.
--
-- No behaviour here. Nine rows in the dictionary, so that
-- supabase/ci/screen_strings.sh finds a row for every string the app says and
-- erp.terminology_alignment_report() can see them.

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('Waiting on you',
     'The header badge carried on every screen, and the heading of the card on Home, when something is waiting on this person to approve it. Both link to My approvals.'),
    ('One approval is waiting on your decision.',
     'The sentence on that card when exactly one thing is waiting. Separate from the plural because English needs "one approval is" and "four approvals are".'),
    ('{count} approvals are waiting on your decision.',
     'The sentence on that card for any other number. {count} is how many tasks are assigned to this person.'),
    ('Nothing is waiting on you. When somebody needs your approval for something, it appears here for you to approve or reject.',
     'The empty state of My approvals. It used to name the approval band that routes a request, which is our word and not the reader''s.'),
    ('Approval history',
     'The panel beside My approvals: what has been through approval, for people who approve things rather than for the administrator who configures them.'),
    ('Every approval that has been raised, and each step of it: what it was for, who asked, and who it went to. Open the record to see what was decided.',
     'The sentence under that panel. The decision itself is kept against the record, which the first column links to.'),
    ('Nothing has been through approval yet. Once something has, every step of it is kept here — what it was for, who asked, and who it went to.',
     'The empty state of that panel.'),
    ('Went to',
     'The column naming the person an approval step landed on.'),
    ('Covering for',
     'The column beside it, naming the person that step would have landed on had this one not been covering for them. Empty where nobody was.')
) as v(text, why)
on conflict (key, locale) do nothing;

do $words$
declare v_missing text;
begin
  select string_agg(quote_literal(t.text), ', ' order by t.text) into v_missing
    from (values
      ('Waiting on you'),
      ('One approval is waiting on your decision.'),
      ('{count} approvals are waiting on your decision.'),
      ('Nothing is waiting on you. When somebody needs your approval for something, it appears here for you to approve or reject.'),
      ('Approval history'),
      ('Every approval that has been raised, and each step of it: what it was for, who asked, and who it went to. Open the record to see what was decided.'),
      ('Nothing has been through approval yet. Once something has, every step of it is kept here — what it was for, who asked, and who it went to.'),
      ('Went to'),
      ('Covering for')
    ) as t(text)
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
