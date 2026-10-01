-- ═════════════════════════════════════════════════════════════════════════════
-- A stock difference goes to stock adjustment
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Decision D7 of the Xero and Unleashed importers: where the stock Unleashed
-- values differs from Xero's Inventory account, the difference is written off
-- to the stock adjustment account, so migration clearing still comes to zero.
-- Opening stock loads at Unleashed's value and the trial balance's Inventory
-- line is excluded as a control account, so without that line the difference
-- stays on clearing and no domain cuts over.
--
-- The trial balance is turned into rows in the browser, which knows the stock
-- value loaded (erp_migration_domains already answers loaded_total_minor) but
-- not which account stock adjustment is in this organisation's chart: the code
-- depends on the chart it runs (erp.chart_account_code). The domain register's
-- door now says it, on the stock domain, as adjustment_account.
--
-- Deployed body, asserted needle, as 20261003900000 does. The end-to-end pilot
-- (supabase/ci/pilot_rehearsal.sh) is the proof: its Xero Inventory differs
-- from its Unleashed stock, and it cuts over every domain at zero clearing.

set lock_timeout = '30s';

do $domains$
declare
  v_sig    constant text := 'public.erp_migration_domains()';
  v_def    text := pg_get_functiondef('public.erp_migration_domains()'::regprocedure);
  v_needle constant text := '''control_purpose'', d.control_purpose,';
  v_hits   integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle);
  if v_hits <> 1 or position('adjustment_account' in v_def) > 0 then
    raise exception 'CLOVEERP_MIGRATION_DOMAINS_UNRECOGNISED: expected the control purpose once in %, found %', v_sig, v_hits
      using hint = 'The deployed body is not the one this migration patches; restate it from pg_get_functiondef.';
  end if;
  execute replace(v_def, v_needle, v_needle
    || ' ''adjustment_account'', case when d.domain_code = ''stock'' then erp.chart_account_code(''stock_adjustment'') end,');
end
$domains$;

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
select erp.assert_authorising_doors_are_volatile();
select erp.assert_no_public_execute();
select erp.assert_ci_coverage();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
