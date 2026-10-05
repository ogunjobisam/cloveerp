set lock_timeout = '30s';

-- =============================================================================
-- 20261006171000  A module that is not installed says so
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-89). Opening
-- Manufacturing in an organisation that has not installed it drew the whole
-- page, and its first verb was refused with words about configuration the
-- visitor could not act on.
--
-- The one before this names the modules in force in the session, and the desk
-- now leaves the others out of the rail, the home page, the palette, the first
-- steps, the guides and the scanner. An address typed or bookmarked still
-- reaches the page, so the page says what is the matter and what to do: the
-- module's own title, that it is not installed here, and either where to
-- install it (to somebody who may configure the organisation, with the
-- existing "Open Configuration") or whom to ask. None of its reads or verbs
-- runs.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The three sentences the page says.
--
-- On production: three rows in erp_ref.resource; nothing else.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The words the page says
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Said on a module''s page when the organisation has not installed it (20261006171000).'
  from (values
    ('This module is not installed in this organisation.'),
    ('Install it on the Configuration screen. Its screens appear here once the change is in force.'),
    ('Ask an administrator to install it on the Configuration screen if you need it.')
  ) as v(text)
on conflict (key, locale) do nothing;

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
select erp.assert_invoker_doors_executable();
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
