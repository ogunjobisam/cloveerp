set lock_timeout = '30s';

-- =============================================================================
-- 20260924510000  A missing line rate says where the rate comes from
-- -----------------------------------------------------------------------------
-- CLOVEERP_INVOICE_LINE_TAX_MISSING told a person to "complete the line
-- amount and VAT rate". Nobody types a line's VAT rate: it is determined as
-- the invoice is issued, from the tax the company has set up
-- (erp.determine_tax_on_commit). Since 20260924500000 the readiness raises
-- this refusal against a draft that no tax rule in force will give a rate,
-- and the only thing that helps there is setting tax up. The next action now
-- says so, in the Configuration screen's own words. What it refuses and why
-- are unchanged.
-- =============================================================================

select erp.register_refusal('CLOVEERP_INVOICE_LINE_TAX_MISSING',
  'A line on this invoice has no net amount or no VAT rate.',
  'Every line of a VAT invoice must show what it came to and the rate applied.',
  'Complete the line''s quantity and price. Its VAT rate is given as the invoice is issued, by the tax the company has set up: if there is none, open Configuration, install Tax and put the change in force, then issue again.');

-- ─────────────────────────────────────────────────────────────────────────────
-- The proof: case 22e of erp_test.document_issue_suite, the draft no tax rule
-- covers, also reads the next action a person is given for it. Still
-- twenty-eight cases.
-- ─────────────────────────────────────────────────────────────────────────────

do $suite$
declare
  v_sig constant text := 'erp_test.document_issue_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a1 constant text := $o$        and v_msg like 'CLOVEERP_INVOICE_LINE_TAX_MISSING:%'
$o$;
  b1 constant text := $n$        and v_msg like 'CLOVEERP_INVOICE_LINE_TAX_MISSING:%'
        -- And the person is sent to the tax set-up, not to a rate nobody
        -- can type (20260924510000).
        and exists (select 1 from erp_ref.refusal f
                     where f.code = 'CLOVEERP_INVOICE_LINE_TAX_MISSING'
                       and f.next_action like '%open Configuration, install Tax%')
$n$;
  n integer;
begin
  n := (length(v_def) - length(replace(v_def, a1, ''))) / length(a1);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: document issue suite anchor found % time(s)', n;
  end if;
  execute replace(v_def, a1, b1);
end
$suite$;

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_suite_verdicts_strict();
