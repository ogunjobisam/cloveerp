-- ═════════════════════════════════════════════════════════════════════════════
-- A receipt at its value is never FIFO
-- ═════════════════════════════════════════════════════════════════════════════
--
-- 20261003900000 added erp.receive_cost_at(), which reads erp.item_cost to
-- know whether a product already had a cost before it moves the value on hand
-- to the exact figure. erp.item_cost holds no row for stock costed first in,
-- first out, so erp.assert_conditional_stores_answer_otherwise() refused it on
-- the live database after the deploy of 1 October: a routine that reads that
-- store and not the layers is the defect class 20260920175000 made visible.
--
-- Here it is not one. erp.receive_cost_at() refuses a FIFO product before it
-- reads erp.item_cost (CLOVEERP_FIFO_COST_NOT_EXACT), and a value that is
-- quantity × unit cost goes to erp.receive_cost(), which opens the layer. The
-- allowance says so, beside the one erp.set_standard_cost() already had.
-- erp_test.exact_stock_and_activation_suite() proves the refusal.

set lock_timeout = '30s';

create or replace function erp.conditional_store_allowance()
returns table (reader text, store text, known_gap boolean, rationale text)
language sql
immutable
set search_path = ''
as $$
  select v.reader, v.store, v.known_gap, v.rationale
    from (values
      ('erp.set_standard_cost'::text, 'erp.item_cost'::text, false,
       'By design. It sets the standard for a product costed at standard and '
       'refuses any other, and a product costed at standard always has its row '
       'here.'::text),
      ('erp.receive_cost_at', 'erp.item_cost', false,
       'By design. It refuses a product costed first in, first out before it '
       'reads this store, and hands a value that is quantity × unit cost to '
       'erp.receive_cost(), which opens the layer (20261004010000).')
    ) as v(reader, store, known_gap, rationale);
$$;

revoke all on function erp.conditional_store_allowance() from public, anon;

select erp.assert_conditional_stores_answer_otherwise();

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
