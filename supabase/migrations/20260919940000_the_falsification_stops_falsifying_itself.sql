-- ─────────────────────────────────────────────────────────────────────────────
-- The falsification stops falsifying itself.
--
-- 20260919930000 added erp.assert_settings_are_written(): every erp.* session
-- setting some installed routine reads with current_setting() must be written
-- by some installed routine with set_config(). It reads pg_proc.prosrc, because
-- that is what the database actually has — needle-patched bodies included.
--
-- Its own suite then falsified it, which is the right instinct and, written the
-- obvious way, a trap. erp_test.audit_source_suite() creates a throwaway
-- routine that reads a setting nothing writes, checks the report finds it and
-- the assertion refuses, and drops it again. To create that routine it carries
-- the DDL as a string — and that string contains
--
--     current_setting('erp.<a name nothing writes>', true)
--
-- inside erp_test.audit_source_suite()'s own prosrc. The report reads every
-- body in erp, erp_ref, erp_meta, erp_ai, erp_test and public, so the suite is
-- a finding about itself, permanently, whether or not the throwaway routine
-- exists. The check would have refused every build from the moment it was
-- written — which is at least the failure in the safe direction, but it is
-- still a check that cannot pass.
--
-- This repository has met this exact shape before and solved it the same way:
-- erp.legacy_refusal_prefix_report() assembles its needle as 'ERP' || 'WARE_'
-- so that the scanner is never its own first finding. So the suite assembles
-- the setting's name instead of writing it, and hands it to format(%L), which
-- leaves no current_setting('erp.…') literal in the suite's body while the
-- routine it creates still carries one.
--
-- And a second, smaller imprecision, fixed while the bodies are open: the
-- report matched prosrc raw, so a read or a write sitting in a comment counted
-- as one. 20260904740000 already settled this argument for the gate scanner —
-- "a rule that reads comments is reading the wrong thing" — and left
-- erp.prosrc_code() behind for it. Both halves of this report now go through
-- it. Checked before writing: over every routine body this repository defines,
-- stripping comments changes neither the set of settings read nor the set
-- written, so this is precision for the next commented-out line rather than a
-- change of verdict today.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. The suite stops naming the setting it is about ────────────────────────

do $suitefix$
declare
  v_def text := pg_get_functiondef('erp_test.audit_source_suite()'::regprocedure);

  v_old1 text := $p$  v_broken  text;
  v_tie     text;$p$;
  v_new1 text := $q$  v_broken  text;
  v_tie     text;
  v_guc     text;$q$;

  v_old2 text := $p$    execute $fn$create function erp_test.zz_reads_an_unwritten_setting()
             returns text language sql stable set search_path = ''
             as $inner$
               select coalesce(nullif(current_setting('erp.nobody_ever_writes_this', true), ''), 'fallback')
             $inner$$fn$;
    select count(*) into v_found from erp.unwritten_setting_report() r
     where r.reference = 'erp.nobody_ever_writes_this';$p$;
  v_new2 text := $q$    -- Assembled, never written whole, and handed to format(%L) rather than
    -- spelled into the DDL. This suite's own body is one of the bodies
    -- erp.unwritten_setting_report() reads, so a literal here would make the
    -- suite a standing finding about itself and the check could never pass.
    -- erp.legacy_refusal_prefix_report() splits its needle for the same
    -- reason (20260919940000).
    v_guc := 'erp.' || 'no' || 'body_ever_writes_this';
    execute format(
      'create function erp_test.zz_reads_an_unwritten_setting() returns text '
      'language sql stable set search_path = '''' as $inner$ '
      'select coalesce(nullif(current_setting(%L, true), ''''), ''fallback'') $inner$',
      v_guc);
    select count(*) into v_found from erp.unwritten_setting_report() r
     where r.reference = v_guc;$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.audit_source_suite() does not build its falsification where this migration expects'
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$suitefix$;

-- ── 2. A read inside a comment is not a read ─────────────────────────────────

do $precision$
declare
  v_rep text := pg_get_functiondef('erp.unwritten_setting_report()'::regprocedure);
  v_ast text := pg_get_functiondef('erp.assert_settings_are_written()'::regprocedure);

  v_old1 text := $p$    select p.prosrc
      from pg_catalog.pg_proc p$p$;
  v_new1 text := $q$    select erp.prosrc_code(p.prosrc) as prosrc
      from pg_catalog.pg_proc p$q$;

  v_old2 text := $p$    cross join lateral regexp_matches(p.prosrc, 'current_setting\s*\(\s*''(erp\.[a-z0-9_]+)''', 'g') m$p$;
  v_new2 text := $q$    cross join lateral regexp_matches(erp.prosrc_code(p.prosrc), 'current_setting\s*\(\s*''(erp\.[a-z0-9_]+)''', 'g') m$q$;
begin
  if (length(v_rep) - length(replace(v_rep, v_old1, ''))) / length(v_old1) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp.unwritten_setting_report() does not read pg_proc where this migration expects'
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  if (length(v_ast) - length(replace(v_ast, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp.assert_settings_are_written() does not count the settings read where this migration expects'
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(v_rep, v_old1, v_new1);
  execute replace(v_ast, v_old2, v_new2);
end
$precision$;

-- ── 3. Both, proved ──────────────────────────────────────────────────────────

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
select erp.assert_invoker_doors_executable();
select erp.assert_session_context_hygiene();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();

-- The one that could not pass before this migration, and the suite that made it
-- so — which still proves, inside its own rollback, that a routine reading a
-- setting nothing writes is refused.
select erp.assert_settings_are_written();
select erp.assert_audit_source_vocabulary();
select erp_test.assert_audit_source_suite();
