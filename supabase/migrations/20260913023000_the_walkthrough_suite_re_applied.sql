-- The walkthrough suite, re-applied.
--
-- The tenth case of erp_test.setup_walkthrough_suite() asked whether the
-- company step is required by the site step with
--
--   'organisation.company' = any ((select s.requires from erp_ref.setup_step s ...))
--
-- which PostgreSQL reads as the subquery form of ANY — the array as a set of
-- rows — and refuses with "malformed array literal". The case now reads the
-- array through the row it belongs to. 20260913020000 is corrected, and, as a
-- pushed migration edited after the fact, is repaired forward: this file
-- re-applies the suite as it now stands, and the register names it.

create or replace function erp_test.setup_walkthrough_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_steps    integer;
  v_observed integer;
  v_branches integer;
  v_screens  integer;
  v_msg      text;
begin
  select count(*), count(*) filter (where observable) into v_steps, v_observed from erp_ref.setup_step;
  select count(*) into v_branches from erp.setup_evidence();
  select count(*) into v_screens from erp_ref.setup_screen;

  return query select 'every screen in the setup order has a first step',
    not exists (select 1 from erp_ref.setup_screen sc
                 where not exists (select 1 from erp_ref.setup_step s where s.screen_path = sc.screen_path and s.seq = 1)),
    format('%s screens', v_screens);
  return query select 'the setup order runs from one to the last screen without a gap',
    (select count(*) from erp_ref.setup_screen) = (select max(seq) from erp_ref.setup_screen),
    format('%s screens, highest seq %s', v_screens, (select max(seq) from erp_ref.setup_screen));
  return query select 'every step names the action it opens',
    not exists (select 1 from erp_ref.setup_step where length(btrim(action_label)) = 0),
    format('%s steps', v_steps);
  return query select 'the evidence function has exactly one branch per observable step',
    v_branches = v_observed, format('%s branches for %s observable steps', v_branches, v_observed);
  return query select 'most of the register completes itself rather than asking',
    v_observed >= v_steps - 8 and v_observed < v_steps,
    format('%s of %s steps are observed', v_observed, v_steps);
  v_msg := erp.assert_setup_walkthrough_actionable();
  return query select 'the assertion reports the register rather than claiming it is complete',
    v_msg ~ '^setup walkthrough: \d+ steps across \d+ screens, \d+ observed', v_msg;
  return query select 'with no organisation in context the evidence is empty, not an error',
    not exists (select 1 from erp.setup_evidence() where satisfied),
    format('%s branches, none satisfied', v_branches);
  return query select 'and each branch still says what it looked for',
    not exists (select 1 from erp.setup_evidence() where evidence is null or length(btrim(evidence)) = 0),
    'every branch returns a sentence';
  return query select 'the report finds nothing to say about a sound register',
    (select count(*) from erp.setup_walkthrough_report()) = 0,
    format('%s finding(s)', (select count(*) from erp.setup_walkthrough_report()));
  return query select 'on the organisation screen the company comes before the site that needs it',
    (select s.seq from erp_ref.setup_step s where s.code = 'organisation.company')
      < (select s.seq from erp_ref.setup_step s where s.code = 'organisation.site')
    and exists (select 1 from erp_ref.setup_step s
                 where s.code = 'organisation.site' and 'organisation.company' = any (s.requires)),
    'organisation.company before organisation.site, and required by it';
  return query select 'a progress row must say something: done, dismissed, or it does not exist',
    exists (select 1 from pg_constraint
             where conrelid = 'erp.setup_progress'::regclass and conname = 'setup_progress_says_something'),
    'setup_progress_says_something';
  return query select 'both writers are registered against the gates they reach',
    (select count(*) from erp_meta.public_write_allowance
      where (function_name, gate) in (('erp_mark_setup_step', 'erp.mark_setup_step'),
                                      ('erp_dismiss_setup_step', 'erp.dismiss_setup_step'))) = 2,
    'erp_meta.public_write_allowance';
end;
$$;

select erp_test.assert_setup_walkthrough_suite();
