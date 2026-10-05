set lock_timeout = '30s';

-- =============================================================================
-- 20261007160000  The Settings home says it is one list
-- -----------------------------------------------------------------------------
-- Found designing the folded rail, 4 October (design "rail", change 2). The
-- Settings home drew two lists for an administrator: the setup order above,
-- and the launchpad's sections below it, the same screens twice. While the
-- setup order was being read it said only "Loading…", and when the read
-- failed or answered nothing the order vanished and left the launchpad, so
-- the page changed shape for reasons nobody could see. On live that read has
-- taken nine to twenty-six seconds (J-38).
--
-- Its help topic was older still. It said Settings has four sections,
-- Organisation, Configure, Operate and Assure; there are six, named People and
-- organisation, System setup, Products and places, Finance setup, Connections
-- and automation, and Records and compliance. It said each section lists only
-- the screens the account may open, which an administrator no longer sees.
-- And its next action named "People and invitations", a screen renamed
-- Onboarding interview on 4 September (20260904690000).
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The '/settings' help topic says what the page now is: one list. Whoever
--      configures the organisation sees the setup order; everybody else, and
--      an administrator until the order has been read, sees the six sections.
--      Its next action starts where the setup order starts. Data only: the
--      topic is not a screen string and has no German row.
--   B. erp_test.settings_home_help_suite, which reads the topic against the
--      setup order, so the help cannot again name a first screen the order
--      does not start with.
--
-- The screen's half is in src/routes/settings.tsx and
-- src/components/erp/walkthrough.tsx: an administrator sees the setup order
-- with every Settings screen it does not name appended, and the launchpad
-- while the order is read, when it fails and when it answers nothing.
--
-- On production: one row of erp_ref.help_topic is rewritten (summary, steps,
-- next action). No table is altered and no organisation's row is touched. An
-- organisation's own note on the screen (help.local.settings) is kept.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The Settings home's help
-- ─────────────────────────────────────────────────────────────────────────────

do $topic$
declare
  c_summary constant text :=
    'Everything that shapes the organisation rather than runs it, in six sections: People and organisation, '
    'System setup, Products and places, Finance setup, Connections and automation, and Records and compliance. '
    'Whoever configures the organisation sees them as one list instead, in the order they are set up, with how '
    'far along each is and what to do next.';
  c_steps constant jsonb := jsonb_build_array(
    'If you configure the organisation, work down the list: the next thing to do is shown above it, and each '
    'screen''s Walkthrough opens its steps.',
    'Everybody else sees the six sections, and so does an administrator until the list has loaded; each section '
    'lists only the screens this account may open.',
    'Switch back to Work from the header; the day''s screens are there.');
  c_next constant text :=
    'Do the next thing the list names; on a new organisation that is the Onboarding interview.';
  v_row text;
begin
  select h.summary || h.steps::text || h.next_action into v_row
    from erp_ref.help_topic h where h.screen_path = '/settings';
  if v_row is null then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the /settings help topic is missing; 20261007160000 rewrites it';
  end if;
  if v_row = c_summary || c_steps::text || c_next then
    raise notice 'the /settings help topic already says it is one list; left as it is';
    return;
  end if;
  if md5(v_row) <> '764444fcdcf9ceb9253cc9b65886b12a' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the /settings help topic is not the text 20261007160000 expects (md5 %)', md5(v_row);
  end if;

  update erp_ref.help_topic
     set summary = c_summary, steps = c_steps, next_action = c_next
   where screen_path = '/settings';
end
$topic$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.settings_home_help_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 2;
  c_sections constant text[] := array['People and organisation', 'System setup', 'Products and places',
                                      'Finance setup', 'Connections and automation', 'Records and compliance'];
  v_cases   integer := 0;
  v_state   text;
  v_topic   record;
  v_first   text;
  v_at      integer;
  v_last    integer := 0;
  v_order   boolean := true;
  v_section text;
begin
  begin
    select h.summary, h.steps, h.next_action into v_topic
      from erp_ref.help_topic h where h.screen_path = '/settings';

    -- ── 1. Six sections, in the order the page shows them ────────────────────
    foreach v_section in array c_sections loop
      v_at := strpos(v_topic.summary, v_section);
      v_order := v_order and v_at > v_last;
      v_last := greatest(v_at, v_last);
    end loop;
    v_cases := v_cases + 1;
    case_name := 'the Settings home''s help names its six sections in the order the page shows them, and says it is one list';
    passed := v_topic.summary is not null
          and v_order
          and v_topic.summary not like '%four sections%'
          and v_topic.summary like '%one list%'
          and jsonb_array_length(v_topic.steps) = 3;
    detail := coalesce(v_state, format('sections in order %s; %s step(s)', v_order,
                coalesce(jsonb_array_length(v_topic.steps), 0)));
    return next;

    -- ── 2. Its next action starts where the setup order starts ───────────────
    select erp.text(h.nav_key) into v_first
      from erp_ref.setup_screen s
      join erp_ref.help_topic h on h.screen_path = s.screen_path
     order by s.seq limit 1;
    v_cases := v_cases + 1;
    case_name := 'the Settings home''s next action names the first screen in the setup order';
    passed := v_first is not null and strpos(v_topic.next_action, v_first) > 0;
    detail := coalesce(v_state, format('first screen %s; next action: %s', v_first, v_topic.next_action));
    return next;
  exception when others then
    v_state := left(sqlerrm, 240);
  end;

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_SETTINGS_HOME_HELP_SUITE_SHRANK: % case(s), expected %; the reading stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the reading stopped; a case that cannot run is a case that fails.';
  end if;
end;
$$;

revoke all on function erp_test.settings_home_help_suite() from public, anon;

comment on function erp_test.settings_home_help_suite() is
  'The Settings home says it is one list (20261007160000): its help names the six sections in the order the page '
  'shows them and no longer says four, and its next action names the first screen in the setup order.';

create or replace function erp_test.assert_settings_home_help_suite()
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
    from erp_test.settings_home_help_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_SETTINGS_HOME_HELP_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The Settings home''s help would describe a page that is not there. Read the case that failed.';
  end if;
  if v_total <> 2 then
    raise exception 'CLOVEERP_SETTINGS_HOME_HELP_SUITE_SHRANK: % case(s), expected 2', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('the Settings home''s help: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_settings_home_help_suite() from public, anon;

comment on function erp_test.assert_settings_home_help_suite() is
  'The Settings home''s help describes the page as it is: six sections, one list, starting where the setup order '
  'starts (20261007160000).';

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
