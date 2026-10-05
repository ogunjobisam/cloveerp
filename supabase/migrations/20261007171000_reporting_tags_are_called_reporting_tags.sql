set lock_timeout = '30s';

-- =============================================================================
-- 20261007171000  Reporting tags are called reporting tags
-- -----------------------------------------------------------------------------
-- Found on the live journey test, 4 October (J-105). The screen at
-- /finance/dimensions is called Extra reporting tags in the navigation and in
-- its own heading, and then called the same thing three other names: every
-- action, label and hint said "dimension", its list of them was headed
-- "Analysis codes" (the English of the source text "Dimensions" since
-- 20260903130000), and its tab title said "Analysis dimensions". Two of its
-- notes told the reader a derivation is "a JsonLogic expression", which is the
-- name of a library, not a thing a finance person sets up.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The English of the screen's own strings says "reporting tag". The keys
--      are the source text, so this is the terminology change 20260903130000
--      made for "Dimensions": the words a person reads change, the source and
--      every organisation's own renaming (erp.resource_override) stay. Two of
--      them, "Dimension" and "Dimensions", are also the labels of the same idea
--      on Which accounts things post to (/finance/account-determination), and
--      read "Reporting tag" and "Reporting tags" there too, as does that
--      screen's hint for the rows they head.
--   B. Rows for the three new strings the screen now says: the two notes
--      without "JsonLogic", and the paragraph under the heading, which was not
--      passed through ui() and so could not be renamed. It now says cost
--      centres come first, because they are kept on this screen
--      (20261007170000).
--   C. The setup steps of the screen say "reporting tag" as well, so the
--      walkthrough and the screen use one name.
--   D. erp_test.reporting_tags_words_suite, which pins it: the screen's words
--      say reporting tag, its notes do not name JsonLogic, and its setup steps
--      do not say dimension.
--
-- Not changed: the evidence sentences of erp.setup_evidence() ("no dimension
-- beyond cost centre yet"), which erp_test.setup_evidence_reference holds a
-- reference copy of; and the door and table names, which are not on a screen.
--
-- On production: fifteen rows of erp_ref.resource (en) are written, three of
-- them new, and three rows of erp_ref.setup_step are reworded. No table is
-- altered and no organisation's row is touched.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The English of the screen's strings
-- ─────────────────────────────────────────────────────────────────────────────

do $words$
declare
  r      record;
  v_now  text;
begin
  for r in
    select v.source, v.was, v.now
      from (values
        ('Dimension', 'Dimension', 'Reporting tag'),
        ('Dimensions', 'Analysis codes', 'Reporting tags'),
        ('Dimensions and values', 'Dimensions and values', 'Reporting tags and values'),
        ('Add or amend a dimension', 'Add or amend a dimension', 'Add or amend a reporting tag'),
        ('Require dimensions on an account', 'Require dimensions on an account',
         'Require reporting tags on an account'),
        ('The dimensions a line to this account must carry.', 'The dimensions a line to this account must carry.',
         'The reporting tags a line to this account must carry.'),
        ('Tick every dimension a line to this account must carry. None ticked removes every requirement.',
         'Tick every dimension a line to this account must carry. None ticked removes every requirement.',
         'Tick every reporting tag a line to this account must carry. None ticked removes every requirement.'),
        ('Optional. Groups values into a tree. Choose a value of the same dimension.',
         'Optional. Groups values into a tree. Choose a value of the same dimension.',
         'Optional. Groups values into a tree. Choose a value of the same reporting tag.'),
        ('Values of a dimension', 'Values of a dimension', 'Values of a reporting tag'),
        ('Preview a document''s dimensions', 'Preview a document''s dimensions',
         'Preview a document''s reporting tags'),
        ('No dimension declared. Add one above; a department creates its own DEPARTMENT dimension.',
         'No dimension declared. Add one above; a department creates its own DEPARTMENT dimension.',
         'No reporting tag yet. Add one above; a department creates its own DEPARTMENT tag.'),
        ('One row per dimension: the dimension and the value a posting under this rule is stamped with. The account and its analysis come from one rule.',
         'One row per dimension: the dimension and the value a posting under this rule is stamped with. The account and its analysis come from one rule.',
         'One row per reporting tag: the tag and the value a posting under this rule is stamped with. The account and its analysis come from one rule.')
      ) v(source, was, now)
  loop
    select res.value into v_now from erp_ref.resource res
     where res.key = erp_ref.ui_key(r.source) and res.locale = 'en';
    if v_now is null then
      raise exception 'CLOVEERP_ANCHOR_MOVED: no English row for the screen string "%"; 20261007171000 rewords it', r.source;
    end if;
    if v_now = r.now then
      continue;
    end if;
    if v_now <> r.was then
      raise exception 'CLOVEERP_ANCHOR_MOVED: the screen string "%" reads "%", not the "%" 20261007171000 expects',
        r.source, v_now, r.was;
    end if;
    update erp_ref.resource
       set value = r.now,
           description = 'Screen wording, keyed by its own source text so a tenant can rename it. Says reporting tag '
                         '(20261007171000).'
     where key = erp_ref.ui_key(r.source) and locale = 'en';
  end loop;
end
$words$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The three new strings
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Extra reporting tags in plain words (20261007171000).'
  from (values
    ('A reporting tag can be worked out from the posting''s facts — document, account, line, company — by a derivation that gives one of the tag''s value codes. It is checked against those facts when it is saved, not discovered at month end.'),
    ('A rule has a scope (when it applies; empty is always) and a condition, both written over the account, the reporting tags and the company. Forbid refuses the line when the condition holds; permit refuses it when the condition does not. Evaluated for every journal, however it was raised.'),
    ('Cost centres come first: every journal line is stamped with one, taken from the document''s own cost centre, then its department, then its site, so the profit and loss and the balance sheet can be read for one of them alone. Any other reporting tag, a project or a region, is stamped from the accounting rule, from the document, or worked out from the document''s facts by a rule you write here; a combination rule says which values an account may carry together.')
  ) v(text)
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The screen's setup steps
-- ─────────────────────────────────────────────────────────────────────────────

do $steps$
declare
  v_was text;
begin
  select md5(string_agg(s.code || '|' || s.title || '|' || s.why || '|' || s.action_label, ',' order by s.code))
    into v_was
    from erp_ref.setup_step s
   where s.code in ('dimensions.declare', 'dimensions.values', 'dimensions.require');
  if exists (select 1 from erp_ref.setup_step s
              where s.code = 'dimensions.declare' and s.action_label = 'Add or amend a reporting tag') then
    raise notice 'the reporting tag steps already say reporting tag; left as they are';
    return;
  end if;
  if v_was is distinct from '27befc19df5581a551e5b91e160e4b2c' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the reporting tag setup steps are not the text 20261007171000 expects (md5 %)', v_was;
  end if;

  update erp_ref.setup_step
     set title = 'Add the other reporting tags you analyse by',
         why = 'Beyond cost centres: project, channel, region. Set it aside if cost centres are enough.',
         action_label = 'Add or amend a reporting tag'
   where code = 'dimensions.declare';
  update erp_ref.setup_step
     set why = 'A reporting tag with no values can be required but never filled.'
   where code = 'dimensions.values';
  update erp_ref.setup_step
     set title = 'Require reporting tags on accounts',
         why = 'An account that requires a reporting tag refuses a posting without one.',
         action_label = 'Require reporting tags on an account'
   where code = 'dimensions.require';
end
$steps$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.reporting_tags_words_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 2;
  c_sources constant text[] := array[
    'Dimension', 'Dimensions', 'Dimensions and values', 'Add or amend a dimension',
    'Require dimensions on an account', 'The dimensions a line to this account must carry.',
    'Tick every dimension a line to this account must carry. None ticked removes every requirement.',
    'Optional. Groups values into a tree. Choose a value of the same dimension.',
    'Values of a dimension', 'Preview a document''s dimensions',
    'No dimension declared. Add one above; a department creates its own DEPARTMENT dimension.',
    'One row per dimension: the dimension and the value a posting under this rule is stamped with. The account and its analysis come from one rule.'];
  c_note_derivation constant text :=
    'A reporting tag can be worked out from the posting''s facts — document, account, line, company — by a '
    'derivation that gives one of the tag''s value codes. It is checked against those facts when it is saved, not '
    'discovered at month end.';
  c_note_rule constant text :=
    'A rule has a scope (when it applies; empty is always) and a condition, both written over the account, the '
    'reporting tags and the company. Forbid refuses the line when the condition holds; permit refuses it when the '
    'condition does not. Evaluated for every journal, however it was raised.';
  v_cases  integer := 0;
  v_state  text;
  v_read   integer;
  v_said   text;
  v_notes  integer;
  v_steps  text;
begin
  begin
    -- ── 1. The screen's strings say reporting tag ────────────────────────────
    select count(*), string_agg(res.value, '; ') filter (where res.value ilike '%dimension%'
                                                          or res.value = 'Analysis codes'
                                                          or res.value not ilike '%tag%')
      into v_read, v_said
      from unnest(c_sources) s(source)
      join erp_ref.resource res on res.key = erp_ref.ui_key(s.source) and res.locale = 'en';
    v_cases := v_cases + 1;
    case_name := 'the reporting tags screen''s words say reporting tag, not dimension or analysis code';
    passed := v_read = cardinality(c_sources) and v_said is null;
    detail := coalesce(v_state, format('%s of %s strings read; still saying otherwise: %s',
                v_read, cardinality(c_sources), coalesce(v_said, 'none')));
    return next;

    -- ── 2. Its notes and its setup steps ─────────────────────────────────────
    select count(*) into v_notes
      from erp_ref.resource res
     where res.locale = 'en'
       and res.key in (erp_ref.ui_key(c_note_derivation), erp_ref.ui_key(c_note_rule))
       and res.value not like '%JsonLogic%';
    select string_agg(s.code, ', ' order by s.code) into v_steps
      from erp_ref.setup_step s
     where s.screen_path = '/finance/dimensions'
       and (s.title || s.why || s.action_label) ilike '%dimension%';
    v_cases := v_cases + 1;
    case_name := 'its notes do not name JsonLogic, and its setup steps do not say dimension';
    passed := v_notes = 2 and v_steps is null;
    detail := coalesce(v_state, format('%s note(s) in plain words; steps still saying dimension: %s',
                v_notes, coalesce(v_steps, 'none')));
    return next;
  exception when others then
    v_state := left(sqlerrm, 240);
  end;

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_REPORTING_TAGS_WORDS_SUITE_SHRANK: % case(s), expected %; the reading stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the reading stopped; a case that cannot run is a case that fails.';
  end if;
end;
$$;

revoke all on function erp_test.reporting_tags_words_suite() from public, anon;

comment on function erp_test.reporting_tags_words_suite() is
  'Reporting tags are called reporting tags (20261007171000): the English of the Extra reporting tags screen''s '
  'strings says reporting tag, its notes do not name JsonLogic, and its setup steps do not say dimension.';

create or replace function erp_test.assert_reporting_tags_words_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.reporting_tags_words_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_REPORTING_TAGS_WORDS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The Extra reporting tags screen would call one thing by several names. Read the case that failed.';
  end if;
  if v_total <> 2 then
    raise exception 'CLOVEERP_REPORTING_TAGS_WORDS_SUITE_SHRANK: % case(s), expected 2', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('reporting tags words: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_reporting_tags_words_suite() from public, anon;

comment on function erp_test.assert_reporting_tags_words_suite() is
  'The Extra reporting tags screen calls a reporting tag a reporting tag, in its strings, notes and setup steps '
  '(20261007171000).';

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
select erp.assert_personal_data_register_sound();
