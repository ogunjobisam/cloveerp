set lock_timeout = '30s';

-- =============================================================================
-- 20261004950000  The bill for what was used is named in plain words
-- -----------------------------------------------------------------------------
-- 20261004940000 registered CLOVEERP_BILLED_BY_CONSUMPTION with the next
-- action "Bill what was used with erp_bill_from_consumption", and raised it
-- from erp.bill_from_receipt() with the same hint. A door's name is something
-- only the people who build Clove ERP would follow, and
-- erp_test.plain_words_suite refuses it, in the register and in the
-- dictionary the screens read a refusal from. The next action now names the
-- action on the Purchasing screen, and the raise says the same.
--
-- Proved by erp_test.plain_words_suite (unchanged).
-- =============================================================================

select erp.register_refusal('CLOVEERP_BILLED_BY_CONSUMPTION',
  'Billing from its receipt goods the supplier still owns.',
  'Consigned goods and samples are the supplier''s until used; billing what arrived would pay for what nobody has used.',
  'Use Bill what was used on the Purchasing screen: it bills what was used and not yet billed, at the agreed price.');

do $receipt$
declare
  v_sig constant text := 'erp.bill_from_receipt(uuid,text,date,date,boolean,bigint,text)';
  v_def text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$            hint = 'Bill what was used with erp_bill_from_consumption.';$o$;
  v_new constant text := $n$            hint = 'Use Bill what was used on the Purchasing screen: it bills what was used and not yet billed, at the agreed price.';$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % names the door in its hint % time(s), not once', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$receipt$;

do $plain$
begin
  if exists (select 1 from erp_ref.refusal f
              where f.code = 'CLOVEERP_BILLED_BY_CONSUMPTION'
                and (erp_test.sounds_internal(f.refused) or erp_test.sounds_internal(f.why)
                     or erp_test.sounds_internal(f.next_action)))
     or exists (select 1 from erp_ref.resource r
                 where r.locale = 'en'
                   and r.key like 'refusal.cloveerp_billed_by_consumption.%'
                   and erp_test.sounds_internal(r.value))
     or position('erp_bill_from_consumption' in pg_get_functiondef(
          'erp.bill_from_receipt(uuid,text,date,date,boolean,bigint,text)'::regprocedure)) > 0 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: CLOVEERP_BILLED_BY_CONSUMPTION still speaks to the builders';
  end if;
end
$plain$;

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
