-- Six presses give their time back.
--
-- Known issue KI-10 (v1 Gate Assessment, 13 October 2026; the owner asked for
-- it fixed the same day). On 5 October 20261005600000 gave six write doors a
-- statement_timeout of 30 seconds, over the 8 seconds the signed-in role is
-- given, while erp.credit_position cost 1.6 seconds a customer and picking took
-- over eight. It was a stopgap, to be handed back once the credit check was
-- fixed and the doors re-measured.
--
-- Both have happened:
--   * the credit check is set-based since 20261006081000. On the live
--     demonstration on 12 and 13 October, erp_dunning_worklist — which called
--     it per overdue customer and always timed out on 4 October — answered 292
--     calls in 133 ms on average and 808 ms at most, and
--     erp_transition_document answered in 386 ms at most (Supabase edge logs);
--   * on a demonstration grown to 1,271 documents at the seed's largest scale,
--     creating an order took 54 to 154 ms, moving one on 7 to 47 ms, picking
--     48 ms, converting a quotation 22 ms, a stock adjustment 109 ms, and the
--     goods receipt receive-as-notified books 159 ms.
--
-- So each door goes back to the role's limit. A door that needs more is a door
-- to make faster, not one to give more time; erp_post_count, erp_record_count
-- and erp_send_purchase_order keep the allowances given them for their own
-- reasons, and the reads given 55 seconds keep theirs.

alter function public.erp_pick_document(uuid, uuid, uuid) reset statement_timeout;
alter function public.erp_raise_stock_adjustment(uuid, text, jsonb, date, text, text) reset statement_timeout;
alter function public.erp_receive_as_notified(uuid, jsonb) reset statement_timeout;
alter function public.erp_create_document_full(text, uuid, uuid, text, date, text, jsonb, text) reset statement_timeout;
alter function public.erp_convert_document(uuid, uuid, uuid, jsonb, text) reset statement_timeout;
alter function public.erp_transition_document(uuid, text, text) reset statement_timeout;

do $handed_back$
declare
  v_kept text;
begin
  select string_agg(p.oid::regprocedure::text, ', ') into v_kept
    from pg_proc p
   where p.oid in ('public.erp_pick_document(uuid, uuid, uuid)'::regprocedure,
                   'public.erp_raise_stock_adjustment(uuid, text, jsonb, date, text, text)'::regprocedure,
                   'public.erp_receive_as_notified(uuid, jsonb)'::regprocedure,
                   'public.erp_create_document_full(text, uuid, uuid, text, date, text, jsonb, text)'::regprocedure,
                   'public.erp_convert_document(uuid, uuid, uuid, jsonb, text)'::regprocedure,
                   'public.erp_transition_document(uuid, text, text)'::regprocedure)
     and exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'statement_timeout=%');
  if v_kept is not null then
    raise exception 'CLOVEERP_PRESS_TIMEOUT_KEPT: % still carries a statement_timeout of its own', v_kept;
  end if;
end
$handed_back$;

-- The generators, which are idempotent and run at the end of every migration.
select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
