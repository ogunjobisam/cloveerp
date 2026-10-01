-- ═════════════════════════════════════════════════════════════════════════════
-- The stock row has eight keys
-- ═════════════════════════════════════════════════════════════════════════════
--
-- 20261003900000 gave a stock row an eighth key, value_minor: the value the
-- legacy system states, so opening stock loads at it rather than at
-- round(quantity × unit cost). erp_test.migration_cutover_suite() pins the
-- shape the domains door returns, and pinned the stock domain at seven keys;
-- the catalogue on main refused it, 39 of 40, after #343 merged.
--
-- The count moves to eight, and the case now also names the key, so a later
-- change that swaps one key for another is caught as well as one that adds.
-- Deployed body, asserted needle, as 20261003910000 patches the same suite.

set lock_timeout = '30s';

do $keys$
declare
  v_sig    constant text := 'erp_test.migration_cutover_suite()';
  v_def    text := pg_get_functiondef('erp_test.migration_cutover_suite()'::regprocedure);
  v_needle constant text := 'where x ->> ''domain_code'' = ''stock'') = 7,';
  v_hits   integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_CUTOVER_SUITE_UNRECOGNISED: expected the stock row shape once in %, found %', v_sig, v_hits
      using hint = 'The deployed body is not the one this migration patches; restate it from pg_get_functiondef.';
  end if;
  execute replace(v_def, v_needle,
    'where x ->> ''domain_code'' = ''stock'') = 8 '
    || 'and exists (select 1 from jsonb_array_elements(res) x, jsonb_array_elements(x -> ''row_keys'') k '
    || 'where x ->> ''domain_code'' = ''stock'' and k ->> ''key'' = ''value_minor'' and not (k ->> ''required'')::boolean),');
end
$keys$;

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
select erp.assert_ci_coverage();
