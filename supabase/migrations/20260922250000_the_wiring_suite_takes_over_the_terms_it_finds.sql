set lock_timeout = '30s';

-- =============================================================================
-- 20260922250000  The wiring suite takes over the terms it finds
-- -----------------------------------------------------------------------------
-- Running every check in the catalogue against this branch found what a green
-- local suite could not:
--
--   FAIL erp_test.assert_configuration_wiring_suite
--   conflicting key value violates exclusion constraint
--   "party_role_terms_no_overlap"
--
-- 20260922230000 is what did it. W3 seeds trading terms for the
-- demonstration's twelve customers so that erp.credit_position() has anything
-- at all to read — before it, the function cross-joined terms and returned no
-- rows, so the whole credit control was inert. erp_test.configuration_wiring_
-- suite() provisions its own organisation, calls
-- erp.ensure_demo_configuration(), and then case 9 plants terms of its own on
-- one of those customers to see the credit hold fire. Two rows in force for one
-- role on one company, which erp.party_role_terms refuses by exclusion
-- constraint, and rightly: a customer has one set of terms at a time.
--
-- ── THE REPAIR ───────────────────────────────────────────────────────────────
--
-- The suite takes over rather than sitting beside. Terms already in force for
-- that role are closed the day before the suite's own begin, which is what an
-- amendment to a customer's terms does in real life and what the date range on
-- the table is for. The case then reads exactly what it meant to: its own
-- limit, and the hold that limit causes.
--
-- Closing rather than deleting matters. The seeded row is the demonstration's
-- own history and the case is about what is in force now, so the honest shape
-- is a term that ended, not a term that never was. A row that somehow begins on
-- or after the suite's own start is deleted instead, because there is no
-- earlier day to close it on.
--
-- ── AND A THING WORTH WRITING DOWN ───────────────────────────────────────────
--
-- erp.party_role_terms is written by erp.ensure_demo_configuration() and by
-- suites inserting rows directly. There is no door and no screen: a customer
-- cannot have their credit limit, their payment terms or their currency set
-- through the product at all, which is why the control W3 wired was reading an
-- empty table in the first place. That is outside this repair and belongs to
-- whichever node builds the customer terms screen — it is noted here because
-- the next person to meet this constraint should not have to find it out the
-- way this branch did.
-- =============================================================================

do $wiring$
declare
  v_sig constant text := 'erp_test.configuration_wiring_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'    insert into erp.party_role_terms (tenant_id, party_role_id, entity_id, currency, credit_limit_minor, credit_status, is_blocked, valid_from)\n'
    || E'    values (v_tenant, v_cust_role, v_entity, v_ccy, 10000, ''watch'', false, current_date - 1);\n';
  v_new constant text :=
       E'    -- The demonstration seeds terms for its customers (20260922230000), so\n'
    || E'    -- this case takes over from what is in force rather than sitting beside\n'
    || E'    -- it: erp.party_role_terms refuses two overlapping rows for one role on\n'
    || E'    -- one company, because a customer has one set of terms at a time\n'
    || E'    -- (20260922250000).\n'
    || E'    delete from erp.party_role_terms t\n'
    || E'     where t.tenant_id = v_tenant and t.party_role_id = v_cust_role\n'
    || E'       and t.entity_id is not distinct from v_entity\n'
    || E'       and t.valid_from >= current_date - 1;\n'
    || E'    update erp.party_role_terms t\n'
    || E'       set valid_to = current_date - 1\n'
    || E'     where t.tenant_id = v_tenant and t.party_role_id = v_cust_role\n'
    || E'       and t.entity_id is not distinct from v_entity\n'
    || E'       and t.valid_from < current_date - 1\n'
    || E'       and (t.valid_to is null or t.valid_to > current_date - 1);\n'
    || E'\n'
    || E'    insert into erp.party_role_terms (tenant_id, party_role_id, entity_id, currency, credit_limit_minor, credit_status, is_blocked, valid_from)\n'
    || E'    values (v_tenant, v_cust_role, v_entity, v_ccy, 10000, ''watch'', false, current_date - 1);\n';
  v_hits integer;
begin
  if position('20260922250000' in v_def) > 0 then
    raise exception 'CLOVEERP_WIRING_UNRECOGNISED: % already takes over the terms it finds', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_WIRING_UNRECOGNISED: % plants its own trading terms % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$wiring$;

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
