set lock_timeout = '30s';

-- =============================================================================
-- 20261006010000  Presses are given the time to finish
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-14, J-19). Three
-- presses a person makes once kept meeting the authenticated role's
-- eight-second statement timeout, and said "That took too long":
--
--   erp_send_purchase_order  locks the order, moves it to sent with its
--                            commitment posting, builds what the email
--                            carries and queues it (J-14)
--   erp_record_count         records the count and, inside its tolerance,
--                            posts its adjustment in the same call; the same
--                            call took 2 s on one press and 14 s on the next
--                            (J-19)
--   erp_post_count           posts that same adjustment by hand (J-19)
--
-- 20261005600000 gave six presses thirty seconds and left these three out.
-- On live, each carries only its search_path: no statement_timeout of its
-- own (checked 4 October).
--
-- ── WHAT THIS IS, AND IS NOT ─────────────────────────────────────────────────
--
-- Each does a bounded piece of work: one order, one count. It is given
-- thirty seconds, as 20261005600000 gave the others; PostgREST applies a
-- function's own statement_timeout to the call. No body changes, and no read
-- is given more: a screen's reads keep the eight seconds.
--
-- It is not the cure. The swing from 2 s to 14 s for the same count is
-- waiting on other sessions' posting, not work; that stays with the posting
-- and credit position work. This only lets a press that would have finished,
-- finish.
-- =============================================================================

alter function public.erp_send_purchase_order(uuid, text, text, text, text) set statement_timeout = '30s';
alter function public.erp_record_count(uuid, numeric) set statement_timeout = '30s';
alter function public.erp_post_count(uuid) set statement_timeout = '30s';

-- Proved here rather than trusted: each door carries the setting, and the
-- six 20261005600000 gave it still do.
do $proof$
declare
  v_missing text;
begin
  select string_agg(s.sig, ', ') into v_missing
    from unnest(array[
      'public.erp_send_purchase_order(uuid,text,text,text,text)',
      'public.erp_record_count(uuid,numeric)',
      'public.erp_post_count(uuid)',
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
