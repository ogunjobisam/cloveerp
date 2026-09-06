-- =============================================================================
-- 20260906147000  The screens that name the new doors, and a fixture that
--                 keeps its shelf life
-- -----------------------------------------------------------------------------
-- Phase 9's last file: the words the new panels say, the help each screen
-- offers, and one fixture repair.
--
-- Every door Phase 9 opened is now named by a screen — the stock policies,
-- the consignment and custody actions and the two proposals on /inventory,
-- the installed modules and their upgrades on /administration/configuration,
-- the channels on /notifications — and a screen string is only a screen
-- string when erp_ref.resource holds it, or `ui()` renders the raw English to
-- somebody reading in German. These are the rows for the strings those panels
-- introduced.
--
-- The fixture: erp_test.production_suite() builds a component batch made
-- thirty days ago and expiring in sixty, which is 67 per cent of its life, and
-- receives it at a site whose configured minimum is 75 per cent. Before
-- 20260906142000 nothing read that setting, so the receipt went through; now
-- it is read, and the fixture is refused by the rule working exactly as it
-- should. The batch is re-pinned to a manufacturing date ten days back rather
-- than the rule being weakened: the setting is the product's, the fixture is
-- ours, and it is the fixture that was wrong.
--
-- Proof: the string coverage check, the door register, the production suite
-- and the console.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A fixture that arrives fresh enough to be received
-- ═════════════════════════════════════════════════════════════════════════════

do $fixture$
declare
  v_def text;
  v_n   text := E'  values (r.tenant_id, v_comp1, ''C1-A'', ''released'', current_date - 30,\n'
             || E'          current_date + 60)\n';
  v_r   text := E'  values (r.tenant_id, v_comp1, ''C1-A'', ''released'', current_date - 10,\n'
             || E'          current_date + 60)\n';
begin
  v_def := pg_get_functiondef('erp_test.production_suite()'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PRODUCTION_FIXTURE_UNRECOGNISED: the C1-A batch is not the fixture this migration re-pins';
  end if;
  execute replace(v_def, v_n, v_r);
end
$fixture$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The words the new panels say
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). Phase 9: the panels for the doors that close the open medium findings.'
  from (values
  ('A pointer into a secret store, such as env://OPS_CHAT_TOKEN. Never the secret.'),
  ('By container where one exists, else by unit'),
  ('By container'),
  ('By unit'),
  ('Change id (blank for a new one)'),
  ('Channels'),
  ('Company code'),
  ('Configure a channel'),
  ('Configured channels'),
  ('Consume consigned stock'),
  ('Credential reference'),
  ('Device step (blank for all)'),
  ('Enabled'),
  ('Give stock the company keeps into someone else''s keeping — a third-party warehouse, a contract manufacturer — where it stands. The owner and the valuation do not move.'),
  ('Hand stock to another keeper'),
  ('How a handling unit is identified and counted, by product class, by site or by the step it is built at.'),
  ('How handling units are identified and counted, for a product class or a site. Proposed as a change, so it is approved and promoted like any other configuration.'),
  ('Identified at'),
  ('In app'),
  ('In force from'),
  ('Module upgrades'),
  ('Module'),
  ('Product class (blank for all)'),
  ('Propose an identity policy'),
  ('Propose how stock is chosen'),
  ('Raises the change that brings this organisation up to the installer''s current version.'),
  ('Site code (blank for all)'),
  ('Site code (blank for the whole company)'),
  ('Stock policies'),
  ('Take a supplier''s consigned stock into the company''s ownership where it stands. Costed at the consigned price and posted against goods received not invoiced, because the supplier will invoice what was used.'),
  ('The allocation policy for a company or one of its sites: which stock a promise takes first. Proposed as a change like any other configuration.'),
  ('The full https URL. A token in the URL is a credential; put it in the reference below instead.'),
  ('The install code from the table above, such as inventory-operations.'),
  ('The install code from the table above.'),
  ('Upgrade a module''s configuration'),
  ('Webhook'),
  ('What a later version of an installer would add that this organisation does not hold. The upgrade is a change like any other: promoted at once where the environment is not live, and left for a second administrator where it is.'),
  ('What an upgrade would add'),
  ('Where the post goes (webhook only)')
) as v(text)
on conflict (key, locale) do update set value = excluded.value;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The help each screen offers names its new doors
-- ═════════════════════════════════════════════════════════════════════════════

select erp_meta.add_help_actions('/administration/configuration',
  array['erp_module_installations', 'erp_module_upgrade_plan', 'erp_upgrade_module_configuration']);

select erp_meta.add_help_actions('/notifications',
  array['erp_upsert_notification_channel', 'erp_notification_channels']);

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_production_suite();
select erp_test.assert_group_translation_suite();
select erp_test.assert_document_value_and_cash_suite();
select erp_test.assert_consignment_suite();
select erp_test.assert_configuration_wiring_suite();
select erp_test.assert_webhook_delivery_suite();
select erp_test.assert_queued_run_suite();
select erp_test.assert_module_upgrade_suite();
select erp_test.assert_promotion_window_suite();
select erp.assert_guidance_sound();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage('de');

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_linter_clean();

do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
