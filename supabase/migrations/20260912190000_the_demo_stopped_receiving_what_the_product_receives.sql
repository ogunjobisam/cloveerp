-- The demonstration received an order the product had already received.
--
-- 20260910165931 taught erp.transition_document() to advance a purchase order
-- when a receipt raised against it is posted: fulfilled in full, the order
-- leaves Sent for Received on its own. erp.seed_demo_history() still drove
-- that step by hand on the very next line, so from 11 September every build
-- died on the first slice of demonstration trading:
--
--   psql:supabase/ci/seed_demo.sql:37: ERROR:
--   CLOVEERP_TRANSITION_NOT_PERMITTED: receive_all is not a declared
--   transition out of received for document
--
-- Twelve minutes of replay, then one second, and the eleven assertion steps
-- behind it never ran at all. The failure was not in the product: the product
-- is right, and the order really is Received. It was in the demonstration
-- repeating a step the product had taken for it.
--
-- So the hand-driven receive_all goes. Closing stays, guarded on the order
-- having actually reached Received — a receipt that covered only part of an
-- order leaves it in Partially received, and close is not declared out of
-- there either. The guard is the difference between a seeder that describes
-- the spine and one that assumes it.
--
-- Patched with pg_get_functiondef() rather than restated. The function is
-- nine hundred lines, four of them are wrong, and a restatement is a second
-- copy of the other eight hundred and ninety-six to keep in step — the same
-- reason 20260906050000 patched this function instead of rewriting it. The
-- match is counted before it is made: a patch that silently finds nothing is
-- how a migration passes having done nothing.

do $do$
declare
  v_def text;
  v_new text;
  v_hit integer;
begin
  v_def := pg_get_functiondef('erp.seed_demo_history(date,date,numeric)'::regprocedure);

  select count(*) into v_hit
    from regexp_matches(
           v_def,
           E'\n    perform erp\\.transition_document\\(v_doc, ''receive_all'', ''demonstration''\\);',
           'g');

  if v_hit <> 1 then
    raise exception
      'CLOVEERP_DEMO_BUILDER_UNRECOGNISED: erp.seed_demo_history() holds % hand-driven receive_all calls, not the one this migration patches', v_hit;
  end if;

  v_new := replace(v_def,
$old$    perform erp.transition_document(v_doc, 'receive_all', 'demonstration');
    if random()::numeric < 0.75 then
      perform erp.transition_document(v_doc, 'close', 'demonstration');
    end if;$old$,
$new$    -- Posting the receipt above advanced this order (20260910165931).
    -- Close only what actually arrived in Received.
    if random()::numeric < 0.75
       and exists (select 1
                     from erp.object_state os
                     join erp.state s on s.id = os.current_state_id
                    where os.tenant_id = v_tenant
                      and os.object_type = 'document'
                      and os.object_id = v_doc
                      and s.code = 'received')
    then
      perform erp.transition_document(v_doc, 'close', 'demonstration');
    end if;$new$);

  if v_new = v_def then
    raise exception 'CLOVEERP_DEMO_BUILDER_UNRECOGNISED: the receipt block in erp.seed_demo_history() is not the one this migration patches';
  end if;

  execute v_new;
end $do$;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();
select erp.assert_public_api_safe();
