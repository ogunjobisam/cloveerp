-- Every step on Purchasing and Stock keeps a list.
--
-- 20261012140000 and its screens gave Purchasing's Payment step, and Stock's
-- Correct and Pass on steps, a list of what waits at them (KI-02, the v1
-- known-issues list): payment runs on their way to being paid, counts whose
-- difference waits on a decision, and stock with a keeper. The register of
-- what each cycle costs still recorded those steps as keeping no list, and
-- erp.assert_flow_step_budgets() refuses a register the screens have moved
-- away from (CLOVEERP_STEP_BUDGET_BROKEN: "drifted"). The actions and steps
-- are unchanged: only the steps keeping no list move, to none.

update erp_meta.flow_budget
   set stages_without_a_list = 0,
       rationale = rationale || ' Since 20261012145000 every step keeps a list: Payment counts the payment runs on '
                             || 'their way to being paid.'
 where flow_code = 'p2p' and stages_without_a_list = 1;

update erp_meta.flow_budget
   set stages_without_a_list = 0,
       rationale = rationale || ' Since 20261012145000 every step keeps a list: Correct counts the counts whose '
                             || 'difference waits on a decision, and Pass on the stock with a keeper.'
 where flow_code = 'stock' and stages_without_a_list = 2;

do $check$
begin
  if exists (select 1 from erp_meta.flow_budget where flow_code in ('p2p', 'stock') and stages_without_a_list <> 0) then
    raise exception 'CLOVEERP_STEP_BUDGET_BROKEN: the Purchasing or Stock register still records a step keeping no list';
  end if;
end
$check$;

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();
