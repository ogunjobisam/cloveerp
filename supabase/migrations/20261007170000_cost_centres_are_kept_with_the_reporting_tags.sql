set lock_timeout = '30s';

-- =============================================================================
-- 20261007170000  Cost centres are kept with the reporting tags
-- -----------------------------------------------------------------------------
-- Found designing the folded rail, 4 October (design "rail", change 3; the
-- owner said yes to the merge). Cost centres and the other reporting tags were
-- two screens in the setup order, eleventh and twelfth, for one idea: what a
-- posting is analysed by. A cost centre IS a reporting tag (the COST_CENTRE
-- dimension), its values live in the same table, and the second screen began
-- by saying "beyond cost centre". Somebody setting up met the same question
-- twice, and the second screen could not show the first one's answer.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The cost-centre step moves onto Extra reporting tags (/finance/dimensions)
--      as its first step; the three tag steps become two to four. Step codes
--      are kept, so erp.setup_evidence() and every organisation's
--      erp.setup_progress rows still match, and a cost centre already added
--      still counts. It takes three statements because UNIQUE (screen_path,
--      seq) is not deferrable.
--   B. /finance/cost-centres leaves the setup order, and the order is
--      renumbered without a gap: Extra reporting tags is eleventh of
--      twenty-six. Its blurb says cost centres come first.
--   C. The help topic of Extra reporting tags carries the cost-centre steps
--      ahead of its own, and the two cost-centre doors (erp_cost_centres,
--      erp_upsert_cost_centre) join its doors, so the help names every door
--      the merged screen calls.
--   D. The /finance/cost-centres help topic is deleted last, on purpose: the
--      foreign keys from erp_ref.setup_screen, erp_ref.first_run_step and
--      erp_ref.notification_route_default refuse the delete if any row still
--      names the screen.
--   E. erp_test.setup_walkthrough_suite gains a case that proves it: cost
--      centres are the first step of the reporting tags screen, and nothing in
--      the setup order, the first-run guide or the help names
--      /finance/cost-centres. Its assertion is re-pinned from 12 cases to 13.
--
-- Nothing becomes unreachable. Both cost-centre doors keep their gates
-- (erp_upsert_cost_centre under finance.configure; erp_cost_centres under
-- finance.read, finance.configure or administration.configure), and the
-- screen's half moves the "Maintain cost centres" action and the "Cost
-- centres" panel onto /finance/dimensions word for word. /finance/cost-centres
-- stays as a route that sends whoever opens it to /finance/dimensions.
-- erp.cost_centres_cover_sites and the site trigger (20261005400000) are not
-- touched: the first cost centre still brings every site and department.
--
-- On production: four rows of erp_ref.setup_step change seq (one changes
-- screen), twenty-seven rows of erp_ref.setup_screen become twenty-six and
-- are renumbered, one help topic is rewritten and one is deleted. No table is
-- altered and no organisation's row is touched. An organisation's own note on
-- the old screen (help.local.finance.cost-centres in erp.resource_override)
-- would no longer be shown; the design asked for that to be checked live.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A–D. The register
-- ─────────────────────────────────────────────────────────────────────────────

do $merge$
declare
  c_summary constant text :=
    'Cost centres and the other reporting tags a posting is analysed by. Cost centres come first: nobody types '
    'one on a document, because the value is taken from the document''s own cost centre, then its department, '
    'then the site it happened at, and every site and department already set up appears as one. Any other tag, '
    'a project or a region, has its values, a rule that works it out from the document, and the combinations an '
    'account allows.';
  c_steps constant jsonb := jsonb_build_array(
    'Add the cost centres this organisation reports on. Use the same code as the site or department where one maps to it.',
    'Group several under a parent where you report on the heading rather than the parts.',
    'Retire one by setting it inactive. The postings that already carry it keep it.',
    'Read the posted-lines column to see which cost centres the books are actually using.',
    'Go to the profit and balance sheet to read results for one of them.',
    'Add any other reporting tag and its values; a department creates its own.',
    'Give it a rule that works it out from the posting''s facts, or leave it to the accounting rule and the document.',
    'Write a combination rule where an account may not carry certain values together.',
    'Preview a document before it posts to see what its lines would be stamped with.');
  c_next constant text :=
    'Check every site and department has a cost centre; then require the reporting tags an account must carry, '
    'so a line without them is refused rather than analysed as nothing.';
  c_blurb constant text :=
    'Cost centres first, before anything posts against them; then any other reporting tags and the accounts that '
    'require them.';
  v_steps  text;
  v_topic  text;
  v_gone   text;
  v_blurb  text;
  v_n      integer;
begin
  select md5(string_agg(s.code || ':' || s.screen_path || ':' || s.seq, ',' order by s.code)) into v_steps
    from erp_ref.setup_step s where s.screen_path in ('/finance/cost-centres', '/finance/dimensions');
  select md5(h.summary || h.steps::text || h.next_action) into v_topic
    from erp_ref.help_topic h where h.screen_path = '/finance/dimensions';
  select md5(h.summary || h.steps::text || h.next_action) into v_gone
    from erp_ref.help_topic h where h.screen_path = '/finance/cost-centres';
  select md5(sc.blurb) into v_blurb from erp_ref.setup_screen sc where sc.screen_path = '/finance/dimensions';

  if v_gone is null
     and exists (select 1 from erp_ref.setup_step s
                  where s.code = 'cost_centres.add' and s.screen_path = '/finance/dimensions' and s.seq = 1) then
    raise notice 'cost centres are already kept with the reporting tags; left as they are';
    return;
  end if;
  if v_steps is distinct from '712873bbe640a5ac5e391dc68c6e88a2'
     or v_topic is distinct from '0f67ddb2bb2dfe01b057fc2fa2121dc6'
     or v_gone is distinct from '305b964de3222bb7c4b33dbb87e4264f'
     or v_blurb is distinct from '9db5e3bfb66be302e1aced15fb9ce207' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the cost-centre and reporting-tag setup rows are not what 20261007170000 expects (steps %, topic %, old topic %, blurb %)',
      v_steps, v_topic, v_gone, v_blurb;
  end if;

  -- A. The cost-centre step leads the reporting tags screen.
  update erp_ref.setup_step set seq = seq + 10 where screen_path = '/finance/dimensions';
  update erp_ref.setup_step set screen_path = '/finance/dimensions', seq = 1 where code = 'cost_centres.add';
  update erp_ref.setup_step set seq = seq - 9 where screen_path = '/finance/dimensions' and seq > 10;

  -- B. The old screen leaves the order, which closes up behind it.
  delete from erp_ref.setup_screen where screen_path = '/finance/cost-centres';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % setup screen row(s) for /finance/cost-centres, expected one', v_n;
  end if;
  update erp_ref.setup_screen set seq = seq + 100;
  update erp_ref.setup_screen sc set seq = o.n
    from (select x.screen_path, row_number() over (order by x.seq)::smallint as n
            from erp_ref.setup_screen x) o
   where o.screen_path = sc.screen_path;
  update erp_ref.setup_screen set blurb = c_blurb where screen_path = '/finance/dimensions';

  -- C. One help topic for the one screen, naming every door it calls.
  update erp_ref.help_topic
     set summary = c_summary, steps = c_steps, next_action = c_next
   where screen_path = '/finance/dimensions';
  perform erp_meta.add_help_actions('/finance/dimensions', array['erp_cost_centres', 'erp_upsert_cost_centre']);

  -- D. Last: a row still naming the old screen makes this refuse.
  delete from erp_ref.help_topic where screen_path = '/finance/cost-centres';
end
$merge$;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.setup_walkthrough_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $function$
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
  -- 20261007170000: one screen for what a posting is analysed by.
  return query select 'cost centres are the first step of the reporting tags screen, and nothing in the setup order, first-run guide or help names /finance/cost-centres',
    exists (select 1 from erp_ref.setup_step s
             where s.code = 'cost_centres.add' and s.screen_path = '/finance/dimensions' and s.seq = 1)
    and (select array_agg(s.code order by s.seq) from erp_ref.setup_step s where s.screen_path = '/finance/dimensions')
          = array['cost_centres.add', 'dimensions.declare', 'dimensions.values', 'dimensions.require']
    and not exists (select 1 from erp_ref.setup_screen sc where sc.screen_path = '/finance/cost-centres')
    and not exists (select 1 from erp_ref.setup_step s where s.screen_path = '/finance/cost-centres')
    and not exists (select 1 from erp_ref.first_run_step f where f.screen_path = '/finance/cost-centres')
    and not exists (select 1 from erp_ref.help_topic h where h.screen_path = '/finance/cost-centres')
    and exists (select 1 from erp_ref.help_topic h
                 where h.screen_path = '/finance/dimensions'
                   and h.actions @> array['erp_cost_centres', 'erp_upsert_cost_centre', 'erp_upsert_dimension']),
    format('reporting tags screen is %s in the order; its steps: %s',
           (select sc.seq from erp_ref.setup_screen sc where sc.screen_path = '/finance/dimensions'),
           (select string_agg(s.code, ', ' order by s.seq) from erp_ref.setup_step s
             where s.screen_path = '/finance/dimensions'));
end;
$function$;

revoke all on function erp_test.setup_walkthrough_suite() from public, anon;

comment on function erp_test.setup_walkthrough_suite() is
  'The setup walkthrough register is sound: every screen has a first step, the order has no gap, every observable '
  'step has one evidence branch, and (20261007170000) cost centres are the first step of the reporting tags screen '
  'with nothing left naming /finance/cost-centres.';

create or replace function erp_test.assert_setup_walkthrough_suite()
returns text
language plpgsql
set search_path = ''
as $function$
declare
  c_expected constant integer := 13;
  v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _setup_walkthrough_result on commit drop as
    select * from erp_test.setup_walkthrough_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_total, v_passed, v_detail
    from _setup_walkthrough_result;
  drop table _setup_walkthrough_result;
  if v_passed < v_total then
    raise exception E'CLOVEERP_SETUP_WALKTHROUGH_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_SETUP_WALKTHROUGH_SUITE_INCOMPLETE: expected % cases, ran %', c_expected, v_total
      using errcode = 'P0001',
            detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('setup walkthrough: %s/%s cases passed', v_passed, v_total);
end;
$function$;

revoke all on function erp_test.assert_setup_walkthrough_suite() from public, anon;

comment on function erp_test.assert_setup_walkthrough_suite() is
  'The setup walkthrough register is sound, thirteen cases, including that cost centres are kept with the '
  'reporting tags (20261007170000).';

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
