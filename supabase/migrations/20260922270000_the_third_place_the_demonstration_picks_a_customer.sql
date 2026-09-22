set lock_timeout = '30s';

-- =============================================================================
-- 20260922270000  The third place the demonstration picks a customer
-- -----------------------------------------------------------------------------
-- Seeding a demonstration the way the build does refused:
--
--   CLOVEERP_CREDIT_HOLD_AT_CAPTURE: the customer is on credit hold (debt is
--   overdue beyond the policy's window) and the policy checks credit when an
--   order is taken
--   PL/pgSQL function erp.seed_demo_history(date, date, numeric) line 865
--
-- 20260922230000 gave the demonstration's customers trading terms, which is
-- what makes erp.credit_position() able to hold anybody at all, and patched
-- the seeder to walk past a customer it is holding. It patched two of the
-- three places the seeder picks one. The third — the half-order path, which
-- picks by the week of the year rather than by the same clause as the other
-- two — was written differently and did not match the anchor.
--
-- ── THE PART WORTH WRITING DOWN ──────────────────────────────────────────────
--
-- That patch guarded its own anchor with a counted-occurrence check and the
-- count came back two, as expected, so it read as proof. It was not. A count of
-- occurrences proves the anchor matched everywhere it appears; it says nothing
-- about the places that needed the same change and are written another way. The
-- question the guard answers is "did I patch what I meant to", not "did I mean
-- to patch enough".
--
-- What would have caught it is what did catch it: seeding a demonstration the
-- way supabase/ci/seed_demo.sql does, rather than running the suites, which
-- build their own small organisations and never walk a year of trading into a
-- credit hold.
--
-- ── THE REPAIR ───────────────────────────────────────────────────────────────
--
-- The same guard, on both halves of the third pick. Both halves, because the
-- count is what the offset is taken against: filtering the pick and not the
-- count would push the offset past the end of the list and quietly stop seeding
-- half-orders on the weeks it overshot, which is a worse defect than the one
-- being fixed — it would seed less and say nothing.
--
-- And the claim that there is no fourth is checked rather than asserted: the
-- number of places the seeder names a demonstration customer has to equal the
-- number of times it asks the credit position.
-- =============================================================================

do $seeder$
declare
  v_sig constant text := 'erp.seed_demo_history(date, date, numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'      select count(*) into v_customers\n'
    || E'        from erp.party p\n'
    || E'       where p.tenant_id = v_tenant and p.code like ''C-%'' and p.status = ''active''::erp.record_status;\n'
    || E'      select p.id into v_customer\n'
    || E'        from erp.party p\n'
    || E'       where p.tenant_id = v_tenant and p.code like ''C-%'' and p.status = ''active''::erp.record_status\n'
    || E'       order by p.code\n'
    || E'      offset extract(week from v_day)::integer % greatest(v_customers, 1)\n'
    || E'       limit 1;\n';
  v_new constant text :=
       E'      -- Not a customer the credit control is holding (20260922270000).\n'
    || E'      -- Both halves: the count is what the offset is taken against, so\n'
    || E'      -- filtering one and not the other would walk off the end of the list.\n'
    || E'      select count(*) into v_customers\n'
    || E'        from erp.party p\n'
    || E'       where p.tenant_id = v_tenant and p.code like ''C-%'' and p.status = ''active''::erp.record_status\n'
    || E'         and not coalesce((select cp.on_hold from erp.credit_position(p.id) cp), false);\n'
    || E'      select p.id into v_customer\n'
    || E'        from erp.party p\n'
    || E'       where p.tenant_id = v_tenant and p.code like ''C-%'' and p.status = ''active''::erp.record_status\n'
    || E'         and not coalesce((select cp.on_hold from erp.credit_position(p.id) cp), false)\n'
    || E'       order by p.code\n'
    || E'      offset extract(week from v_day)::integer % greatest(v_customers, 1)\n'
    || E'       limit 1;\n';
  v_hits integer;
begin
  if position('20260922270000' in v_def) > 0 then
    raise exception 'CLOVEERP_SEEDER_UNRECOGNISED: % already walks past a held customer everywhere', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SEEDER_UNRECOGNISED: % picks a customer by the week % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$seeder$;

do $all$
declare
  v_def  text := pg_get_functiondef('erp.seed_demo_history(date, date, numeric)'::regprocedure);
  v_pick_t constant text := 'p.code like ''C-%''';
  v_ask_t  constant text := 'erp.credit_position(p.id)';
  v_pick integer;
  v_ask  integer;
begin
  v_pick := (length(v_def) - length(replace(v_def, v_pick_t, ''))) / length(v_pick_t);
  v_ask  := (length(v_def) - length(replace(v_def, v_ask_t, ''))) / length(v_ask_t);
  if v_pick <> v_ask then
    raise exception
      'CLOVEERP_SEEDER_PICKS_UNGUARDED: the seeder names a demonstration customer % time(s) and asks the credit position % time(s)',
      v_pick, v_ask
      using hint = 'Every place the seeder picks a customer has to walk past one the credit control is holding, or the demonstration stops being able to trade with them.';
  end if;
end
$all$;

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
