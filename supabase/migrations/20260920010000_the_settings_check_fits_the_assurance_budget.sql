-- ─────────────────────────────────────────────────────────────────────────────
-- The settings check fits the assurance budget.
--
-- erp.assert_settings_are_written() (20260919930000) cost 213 ms on a database
-- built from empty and timed out on live, in the deploy's own proof step:
--
--   ERROR:  canceling statement due to statement timeout
--   CONTEXT:  SQL function "prosrc_code" statement 1
--   PL/pgSQL function erp.assert_settings_are_written() line 29
--   PL/pgSQL function erp.platform_assurance() line 24
--
-- Nothing was wrong with the schema: steps one to thirteen of that deploy all
-- succeeded, the release was recorded and email still left. What failed was the
-- proof, and because erp.assert_whole_database_reconciles() runs after
-- erp.platform_assurance() in that step, it never ran at all. Live was left
-- carrying a correct schema that nothing had checked, which is its own kind of
-- wrong and blocks every deploy behind it.
--
-- The cost was never the regular expression that finds the settings. It was
-- erp.prosrc_code() — two regexp_replace passes, one of them non-greedy with
-- the s flag — run over the body of EVERY routine in six schemas, some of them
-- very large, to find the twenty or so that mention a session setting at all.
-- The check paid for reading the whole product in order to look at a fraction
-- of it.
--
-- Three changes, none of which alter a single verdict:
--
--  1. Pre-filter on the raw source. erp.prosrc_code() only ever removes text —
--     comments — and it replaces what it removes with a space, never with
--     nothing. So it cannot create a substring that was not there, and
--     prosrc_code(x) containing 'current_setting' implies x does too. Filtering
--     on the raw column is therefore a strict superset of what can match: no
--     routine that would have been found is dropped, and the comment-stripping
--     stops running on the thousands of bodies that never mention a setting.
--
--  2. Stop carrying the body through a DISTINCT. The reader side selected
--     `distinct m[1], r.prosrc` and the only consumer of it then took
--     `distinct guc`. The body was never read, but every de-duplication sorted
--     or hashed megabytes of text to discover that identical bodies are
--     identical.
--
--  3. The same pre-filter on the blindness count, which scans separately and
--     must: a guard that asks "did the scraper find anything at all" is worth
--     having only if it reads the same corpus the report reads, and the two
--     live in different routines because erp_meta.diagnostic_check names them
--     separately. With the filter each pass touches the same twenty bodies, so
--     the second pass is no longer a cost worth folding away at the price of
--     changing a signature the register points at.
--
-- What is deliberately NOT done: the check is not narrowed. erp_test stays in
-- the namespace list, because a suite that reads a setting nothing writes is a
-- real finding and — with the filter — a free one to look for; and the
-- blindness guard stays exactly as it was. A scraper that quietly reads less
-- looks precisely like one with nothing to complain about, and this repository
-- has had that lesson twice tonight already.
-- ─────────────────────────────────────────────────────────────────────────────

do $report$
declare
  v_def text := pg_get_functiondef('erp.unwritten_setting_report()'::regprocedure);

  v_old1 text := $p$    select erp.prosrc_code(p.prosrc) as prosrc
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'public')
       and p.prokind in ('f', 'p')
  ),$p$;
  v_new1 text := $q$    select erp.prosrc_code(p.prosrc) as prosrc
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'public')
       and p.prokind in ('f', 'p')
       -- The whole cost of this check was stripping comments from every body in
       -- the product to find the handful that mention a setting. prosrc_code()
       -- only removes text, and replaces what it removes with a space rather
       -- than with nothing, so it can never bring two characters together that
       -- the raw source kept apart. Both halves of this filter are therefore a
       -- strict superset of what the patterns below can match: the function
       -- name has to appear, and so does the opening quote of an erp setting,
       -- because the patterns require ''erp. with nothing between the quote and
       -- the name. Over this repository that is 135 bodies rather than 2,363,
       -- and a quarter of the text rather than all of it, with every verdict
       -- unchanged (20260920010000).
       and (p.prosrc like '%current_setting%' or p.prosrc like '%set_config%')
       and p.prosrc like '%''erp.%'
  ),$q$;

  v_old2 text := $p$    select distinct m[1] as guc, r.prosrc
      from routine r$p$;
  v_new2 text := $q$    -- The body is not selected. Nothing downstream reads it, and carrying it
    -- made every de-duplication sort or hash the text of every routine.
    select distinct m[1] as guc
      from routine r$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp.unwritten_setting_report() does not read pg_proc where this migration expects'
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$report$;

do $blind$
declare
  v_def text := pg_get_functiondef('erp.assert_settings_are_written()'::regprocedure);

  v_old text := $p$    cross join lateral regexp_matches(erp.prosrc_code(p.prosrc), 'current_setting\s*\(\s*''(erp\.[a-z0-9_]+)''', 'g') m
   where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'public')
     and p.prokind in ('f', 'p');$p$;
  v_new text := $q$    cross join lateral regexp_matches(erp.prosrc_code(p.prosrc), 'current_setting\s*\(\s*''(erp\.[a-z0-9_]+)''', 'g') m
   where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'public')
     and p.prokind in ('f', 'p')
     -- The same strict superset the report filters on, for the same reason,
     -- and it must be the same corpus or this guard stops describing the
     -- report it guards (20260920010000).
     and p.prosrc like '%current_setting%'
     and p.prosrc like '%''erp.%';$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp.assert_settings_are_written() does not count the settings read where this migration expects'
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(v_def, v_old, v_new);
end
$blind$;

-- ── Proved ───────────────────────────────────────────────────────────────────
--
-- The check still answers, and the suite that falsifies it still falsifies it:
-- its ninth case builds a routine that reads a setting nothing writes, and the
-- pre-filter has to let that routine through for the case to pass. An
-- equivalence argument that the suite could not see would not be one.

select erp.assert_settings_are_written();
select erp.assert_audit_source_vocabulary();
select erp.assert_diagnostics_registered();
select erp_test.assert_audit_source_suite();
