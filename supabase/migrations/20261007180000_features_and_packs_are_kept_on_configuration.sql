set lock_timeout = '30s';

-- =============================================================================
-- 20261007180000  Features and packs are kept on Configuration
-- -----------------------------------------------------------------------------
-- Found designing the folded rail, 4 October (design "rail", change 4; the
-- owner said yes to the merge). Features and content (/administration/packs)
-- and Configuration were the fourth and fifth screens of the setup order, and
-- one job: prepare the organisation's configuration, then approve and promote
-- it. A feature switch or a pack only ever prepared a change, and the screen
-- had to send the reader to Configuration to land it ("Approve and promote it
-- on Configuration"). Configuration's first step, installing finance, required
-- a pack applied on the screen before. Two stops for one sequence, and the
-- second could not show what the first had prepared.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The three packs steps move onto Configuration as its first three
--      (packs.features, packs.base, packs.decide keep 1, 2 and 3); the four
--      configuration steps become four to seven. Step codes are kept, so
--      erp.setup_evidence() and every organisation's erp.setup_progress rows
--      still match, and a pack already applied still counts.
--      configuration.finance still requires packs.base, which now comes two
--      steps before it on the same screen. It takes three statements because
--      UNIQUE (screen_path, seq) is not deferrable.
--   B. The administrator's first-run step 3 ("Apply the ready-made setup")
--      opens Configuration. Its evidence is keyed on (guide, seq) and does not
--      change, nor does anybody's erp.first_run_progress.
--   C. /administration/packs leaves the setup order, and the order is
--      renumbered without a gap: Configuration is fourth of twenty-five. Its
--      blurb says features and packs come first.
--   D. The help topic of Configuration carries the packs steps ahead of its
--      own, and the nine doors the features and packs section calls join its
--      doors, so the help names every door the merged screen calls.
--   E. The /administration/packs help topic is deleted last, on purpose: the
--      foreign keys from erp_ref.setup_screen, erp_ref.first_run_step and
--      erp_ref.notification_route_default refuse the delete if any row still
--      names the screen.
--   F. erp_test.setup_walkthrough_suite, as 20261007170000 left it, gains a
--      case that proves it: the packs steps come before installing on
--      Configuration, and nothing in the setup order, the first-run guide, the
--      help or the notice links names /administration/packs. Its assertion is
--      re-pinned from 13 cases to 14.
--
-- Nothing becomes unreachable. No door, gate or permission changes: the
-- feature and pack writers (erp_set_capability, erp_apply_preset,
-- erp_apply_content_pack, erp_answer_pack_decision, erp_pack_plan) keep their
-- own checks, and the reads (erp_capabilities, erp_presets, erp_content_packs,
-- erp_pack_acceptance) keep theirs. The screen's half moves the Readiness
-- panel, the Features and Content packs tabs and their closing note onto
-- /administration/configuration word for word, shown read-only to whoever may
-- not configure, as /administration/packs showed them. /administration/packs
-- stays as a route that sends whoever opens it to that section.
--
-- On production: seven rows of erp_ref.setup_step change seq (three change
-- screen), one row of erp_ref.first_run_step changes screen, twenty-six rows
-- of erp_ref.setup_screen become twenty-five and are renumbered, one help
-- topic is rewritten and one is deleted. No table is altered and no
-- organisation's row is touched; the one organisation with packs.base done
-- keeps it, because the step code is kept. No organisation has a help note
-- (help.local.administration.packs) or a rename on the old screen (read live,
-- 5 October), so nothing an organisation wrote is lost.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A–E. The register
-- ─────────────────────────────────────────────────────────────────────────────

do $merge$
declare
  c_summary constant text :=
    'Features, the starter content packs and the modules this organisation uses, with what each setting means '
    'and its consequence. Features come first, because what a pack carries depends on which are on; then the '
    'packs of vocabularies, reason codes, states, tolerances and finance; then the modules, finance first. Each '
    'arrives as a change to read, approve and promote.';
  c_steps constant jsonb := jsonb_build_array(
    'Choose a preset that matches the organisation, and switch on the features it uses.',
    'Apply the packs, and answer any decision a pack asks; each arrives as a change.',
    'Readiness says whether the result is complete, and what this organisation cannot do yet.',
    'Install a module: its configuration arrives as a change set.',
    'Read each setting''s consequence before changing it.',
    'Changes are promoted, never typed into a live organisation.');
  c_next constant text :=
    'Switch on the features you use and apply the base packs, then install the modules you use and approve and '
    'promote them.';
  c_blurb constant text :=
    'Features first, then the starter packs, then the modules you use, finance first; each arrives as a change '
    'to approve and promote.';
  v_steps  text;
  v_guide  text;
  v_topic  text;
  v_gone   text;
  v_blurb  text;
  v_n      integer;
begin
  select md5(string_agg(s.code || ':' || s.screen_path || ':' || s.seq, ',' order by s.code)) into v_steps
    from erp_ref.setup_step s where s.screen_path in ('/administration/packs', '/administration/configuration');
  select md5(string_agg(f.guide_code || ':' || f.seq || ':' || f.screen_path, ',' order by f.guide_code, f.seq))
    into v_guide
    from erp_ref.first_run_step f where f.screen_path in ('/administration/packs', '/administration/configuration');
  select md5(h.summary || h.steps::text || h.next_action) into v_topic
    from erp_ref.help_topic h where h.screen_path = '/administration/configuration';
  select md5(h.summary || h.steps::text || h.next_action) into v_gone
    from erp_ref.help_topic h where h.screen_path = '/administration/packs';
  select md5(sc.blurb) into v_blurb from erp_ref.setup_screen sc where sc.screen_path = '/administration/configuration';

  if v_gone is null
     and exists (select 1 from erp_ref.setup_step s
                  where s.code = 'packs.features' and s.screen_path = '/administration/configuration' and s.seq = 1) then
    raise notice 'features and packs are already kept on Configuration; left as they are';
    return;
  end if;
  if v_steps is distinct from 'f7cab28974f3fc2bda19d75589481caa'
     or v_guide is distinct from 'b067f3d3a9323ca838e544b562e752ef'
     or v_topic is distinct from 'd0c652a74eab4df78fb246839ef1485e'
     or v_gone is distinct from '90c18335412a69dec4d8e06643e32afb'
     or v_blurb is distinct from 'be0c3a66f74fb4d5e053df4227020015' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the packs and configuration setup rows are not what 20261007180000 expects (steps %, guide %, topic %, old topic %, blurb %)',
      v_steps, v_guide, v_topic, v_gone, v_blurb;
  end if;

  -- A. The packs steps lead Configuration; its own steps follow them.
  update erp_ref.setup_step set seq = seq + 10 where screen_path = '/administration/configuration';
  update erp_ref.setup_step set screen_path = '/administration/configuration' where screen_path = '/administration/packs';
  update erp_ref.setup_step set seq = seq - 7 where screen_path = '/administration/configuration' and seq > 10;

  -- B. The administrator's ready-made setup step opens Configuration.
  update erp_ref.first_run_step set screen_path = '/administration/configuration'
   where guide_code = 'administrator' and seq = 3 and screen_path = '/administration/packs';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % first-run step(s) for /administration/packs, expected one', v_n;
  end if;

  -- C. The old screen leaves the order, which closes up behind it.
  delete from erp_ref.setup_screen where screen_path = '/administration/packs';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % setup screen row(s) for /administration/packs, expected one', v_n;
  end if;
  update erp_ref.setup_screen set seq = seq + 100;
  update erp_ref.setup_screen sc set seq = o.n
    from (select x.screen_path, row_number() over (order by x.seq)::smallint as n
            from erp_ref.setup_screen x) o
   where o.screen_path = sc.screen_path;
  update erp_ref.setup_screen set blurb = c_blurb where screen_path = '/administration/configuration';

  -- D. One help topic for the one screen, naming every door it calls.
  update erp_ref.help_topic
     set summary = c_summary, steps = c_steps, next_action = c_next
   where screen_path = '/administration/configuration';
  perform erp_meta.add_help_actions('/administration/configuration',
    array['erp_capabilities', 'erp_set_capability', 'erp_presets', 'erp_apply_preset', 'erp_content_packs',
          'erp_pack_plan', 'erp_answer_pack_decision', 'erp_apply_content_pack', 'erp_pack_acceptance']);

  -- E. Last: a row still naming the old screen makes this refuse.
  delete from erp_ref.help_topic where screen_path = '/administration/packs';
end
$merge$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. The proof
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
  -- 20261007180000: features and content are the first section of Configuration.
  return query select 'features and packs come before installing on Configuration, and nothing in the setup order, first-run guide, help or notices names /administration/packs',
    (select array_agg(s.code order by s.seq) from erp_ref.setup_step s
      where s.screen_path = '/administration/configuration')
      = array['packs.features', 'packs.base', 'packs.decide', 'configuration.finance', 'configuration.modules',
              'configuration.promote', 'configuration.reason_codes']
    and (select array_agg(s.seq::integer order by s.seq) from erp_ref.setup_step s
          where s.screen_path = '/administration/configuration') = array[1, 2, 3, 4, 5, 6, 7]
    and not exists (select 1 from erp_ref.setup_screen sc where sc.screen_path = '/administration/packs')
    and not exists (select 1 from erp_ref.setup_step s where s.screen_path = '/administration/packs')
    and not exists (select 1 from erp_ref.first_run_step f where f.screen_path = '/administration/packs')
    and not exists (select 1 from erp_ref.notification_route_default n where n.link_path = '/administration/packs')
    and not exists (select 1 from erp_ref.help_topic h where h.screen_path = '/administration/packs')
    and exists (select 1 from erp_ref.first_run_step f
                 where f.guide_code = 'administrator' and f.seq = 3
                   and f.screen_path = '/administration/configuration')
    and exists (select 1 from erp_ref.help_topic h
                 where h.screen_path = '/administration/configuration'
                   and h.actions @> array['erp_capabilities', 'erp_set_capability', 'erp_presets', 'erp_apply_preset',
                                          'erp_content_packs', 'erp_pack_plan', 'erp_answer_pack_decision',
                                          'erp_apply_content_pack', 'erp_pack_acceptance', 'erp_submit_change_set']),
    format('Configuration is %s in the order; its steps: %s',
           (select sc.seq from erp_ref.setup_screen sc where sc.screen_path = '/administration/configuration'),
           (select string_agg(s.seq || ' ' || s.code, ', ' order by s.seq) from erp_ref.setup_step s
             where s.screen_path = '/administration/configuration'));
end;
$function$;

revoke all on function erp_test.setup_walkthrough_suite() from public, anon;

comment on function erp_test.setup_walkthrough_suite() is
  'The setup walkthrough register is sound: every screen has a first step, the order has no gap, every observable '
  'step has one evidence branch, (20261007170000) cost centres are the first step of the reporting tags screen '
  'with nothing left naming /finance/cost-centres, and (20261007180000) features and packs come before installing '
  'on Configuration with nothing left naming /administration/packs.';

create or replace function erp_test.assert_setup_walkthrough_suite()
returns text
language plpgsql
set search_path = ''
as $function$
declare
  c_expected constant integer := 14;
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
  'The setup walkthrough register is sound, fourteen cases, including that cost centres are kept with the '
  'reporting tags (20261007170000) and features and packs are kept on Configuration (20261007180000).';

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
