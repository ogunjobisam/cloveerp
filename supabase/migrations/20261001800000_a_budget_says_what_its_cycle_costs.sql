-- ═════════════════════════════════════════════════════════════════════════════
-- A budget says what its cycle costs
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The procurement and order-to-cash rows of erp_meta.flow_budget still read as
-- they did before either cycle was simplified: "today's cost", with the plan's
-- target of six and seven still to reach. Both were reached. erp_test.
-- step_budget_suite walks procurement in six presses by three people
-- (20260923200000) and order to cash in seven by four (20260924100000), and
-- the §10 gates hold. The budget figures are what each module's strip draws,
-- which supabase/ci/flow_steps.sh counts; only the words beside them were
-- stale. This restates them in the form the stock, money and make rows
-- already use: what the strip draws, and what the cycle costs and where that
-- is walked. No figure changes.

update erp_meta.flow_budget
   set rationale =
         'The fourteen actions over eight steps are what the Purchasing screen''s strip draws, so a fifteenth '
      || 'fails the build. The cycle itself is walked by erp_test.step_budget_suite at six presses by three '
      || 'people, from a requisition to a registered bill: received, closed and ordered are derived from what '
      || 'happened, not pressed, and an approver who is not an administrator approves in one press (20260923200000).'
 where flow_code = 'p2p'
   and rationale like 'Today''s cost, recorded so a fifteenth verb fails the build.%';

update erp_meta.flow_budget
   set rationale =
         'The five actions are what the Sales screen''s strip draws; most of order to cash is reached from '
      || 'the document screen rather than the strip. The cycle itself is walked by erp_test.step_budget_suite '
      || 'at seven presses by four people, from a quotation to a filed invoice paid and a closed order, with '
      || 'the six moves nobody pressed made by what happened (20260924100000).'
 where flow_code = 'o2c'
   and rationale like 'Today''s cost of the strip,%';

do $rationale$
begin
  if exists (select 1 from erp_meta.flow_budget b
              where b.flow_code in ('p2p', 'o2c')
                and b.rationale not like '%walked by erp_test.step_budget_suite%') then
    raise exception 'CLOVEERP_ANCHOR_MOVED: a procurement or order-to-cash budget no longer reads as it did '
                    'before 20261001800000, so this migration restated neither';
  end if;
  if exists (select 1 from erp_meta.flow_budget b where b.rationale ilike '%target is%') then
    raise exception 'CLOVEERP_ANCHOR_MOVED: a flow budget still names a target the step budget suite walks';
  end if;
end
$rationale$;

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
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
