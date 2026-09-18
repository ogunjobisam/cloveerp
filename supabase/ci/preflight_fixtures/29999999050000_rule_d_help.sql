-- Rule D. /preflight/fixture has never had a help topic, so
-- erp_meta.add_help_actions() finds no row to update and raises
-- CLOVEERP_NO_HELP_TOPIC, and the migration rolls back whole.

select erp_meta.add_help_actions('/preflight/fixture', array['erp_planned_orders']);
