set lock_timeout = '30s';

-- =============================================================================
-- 20261005600000  A press is given the time to finish
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October, with five people's worth
-- of sessions open. The writes a person presses once kept meeting the
-- authenticated role's eight-second statement timeout:
--
--   erp_pick_document          never finished: six tries, cancelled at 8 s
--                              each, on a database otherwise answering in
--                              half a second
--   erp_raise_stock_adjustment cancelled three times in four; the one that
--                              finished took 6.9 s
--   erp_receive_as_notified    cancelled three times running, then 3.7 s
--   erp_create_document_full   cancelled at 9.3 s, then 2.5 s
--   erp_convert_document       up to 7.2 s
--   erp_transition_document    up to 7.4 s
--
-- "That took too long" on a press that posts one document reads as broken,
-- and the person presses again, which is the same work asked for twice.
--
-- ── WHAT THIS IS, AND IS NOT ─────────────────────────────────────────────────
--
-- Each of these does a bounded piece of work: one order, one notice, one
-- document. They are given thirty seconds, the way erp_accept_interview and
-- erp_platform_assurance have fifty-five (20261001902000): PostgREST applies
-- a function's own statement_timeout to the call. No read is given more
-- here: a screen's reads keep the eight seconds, so a slow read is still cut
-- off and is not left running behind a screen nobody is looking at.
--
-- It is not the cure. The time goes where the pick's does: erp.credit_position
-- took 1.6 s for one customer on the quiet database (2.3 s inside
-- erp.check_release_to_fulfilment), a function per order per customer, and
-- the dunning worklist asks it of every overdue customer, which is why that
-- read never finishes. That is its own piece of work, with figures to hold it
-- to. This only lets a press that would have finished, finish.
-- =============================================================================

alter function public.erp_pick_document(uuid, uuid, uuid) set statement_timeout = '30s';
alter function public.erp_raise_stock_adjustment(uuid, text, jsonb, date, text, text) set statement_timeout = '30s';
alter function public.erp_receive_as_notified(uuid, jsonb) set statement_timeout = '30s';
alter function public.erp_create_document_full(text, uuid, uuid, text, date, text, jsonb, text) set statement_timeout = '30s';
alter function public.erp_convert_document(uuid, uuid, uuid, jsonb, text) set statement_timeout = '30s';
alter function public.erp_transition_document(uuid, text, text) set statement_timeout = '30s';

-- Proved here rather than trusted: each door carries the setting.
do $proof$
declare
  v_missing text;
begin
  select string_agg(s.sig, ', ') into v_missing
    from unnest(array[
      'public.erp_pick_document(uuid,uuid,uuid)',
      'public.erp_raise_stock_adjustment(uuid,text,jsonb,date,text,text)',
      'public.erp_receive_as_notified(uuid,jsonb)',
      'public.erp_create_document_full(text,uuid,uuid,text,date,text,jsonb,text)',
      'public.erp_convert_document(uuid,uuid,uuid,jsonb,text)',
      'public.erp_transition_document(uuid,text,text)']) as s(sig)
   where not exists (
     select 1 from pg_catalog.pg_proc p
      where p.oid = s.sig::regprocedure
        and 'statement_timeout=30s' = any (coalesce(p.proconfig, '{}')));
  if v_missing is not null then
    raise exception 'CLOVEERP_PRESS_TIMEOUT_MISSING: no statement_timeout of 30s on %', v_missing;
  end if;

end
$proof$;

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
select erp.assert_personal_data_register_sound();
