set lock_timeout = '30s';

-- =============================================================================
-- 20261007123000  Notices made together keep one order
-- -----------------------------------------------------------------------------
-- Found in CI on the pull request of 20261007120000 (J-132). The Inbox door,
-- public.erp_my_notifications, orders unread first and then newest first,
-- and nothing after that. Notices written in one transaction share their
-- created_at (now() is the transaction's time): an approval routed to
-- several people, a receipt's notices, a digest and its parts. Two such
-- notices came back in whichever order the plan met them, and the plan is
-- not the same for every caller: read by the owner and read signed in, under
-- row security, the same two notices came back in opposite orders, which
-- erp_test.notice_links_suite's third case compares and CI caught. On a
-- screen it means the Inbox can reorder itself between two refreshes, and
-- a limit can drop a different notice each time.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_my_notifications orders by the notice's id last, both where
--      it takes the limit and where it answers, so one caller's notices come
--      back in one order however they are read.
--   B. erp_test.notice_order_suite: twelve notices made together come back in
--      the same order read by the owner and signed in, and a limit takes the
--      first of that order.
--
-- On production: one routine is edited where it orders. No table is altered
-- and no row is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. One order, however the notices are read
-- ─────────────────────────────────────────────────────────────────────────────

do $order$
declare
  v_sig  constant text := 'public.erp_my_notifications(integer)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$     order by (x.status in ('sent', 'delivered')) desc, x.created_at desc
$o$;
  v_new1 constant text := $n$     -- The id last, so notices made together keep one order (20261007123000).
     order by (x.status in ('sent', 'delivered')) desc, x.created_at desc, x.id desc
$n$;
  v_old2 constant text := $o$         order by (n.status in ('sent', 'delivered')) desc, n.created_at desc), '[]'::jsonb)$o$;
  v_new2 constant text := $n$         order by (n.status in ('sent', 'delivered')) desc, n.created_at desc, n.id desc), '[]'::jsonb)$n$;
begin
  if strpos(v_src, '20261007123000') > 0 then
    raise notice '% already keeps one order; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'bff33dc365382ff544cf1407375366c3' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007123000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$order$;

comment on function public.erp_my_notifications(integer) is
  'The caller''s own messages, unread first, then newest first, then by id, so notices made together keep one order '
  '(20261007123000), each with links to what it is about, named in the reader''s language, a document link with its '
  'number (20261007120000, J-132). Keyed to the session''s organisation and erp.current_principal_id(); it authorises nothing.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.notice_order_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 2;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  v_owner  text := current_user;
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_read   jsonb; v_signed jsonb; v_five jsonb;
  v_ids    text[];
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation whose administrator has twelve notices made together';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zznor-' || v_tag, 'Notice Order Suite',
      'admin@zznor-' || v_tag || '.test', 'Order Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zznor-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    -- One transaction, so one created_at, and ids in no particular order.
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body,
                                  status, sent_at, delivered_at)
    select rb.tenant_id, 'low', rb.admin_user_id, 'in_app', 'Made together ' || g, 'Notice ' || g || '.',
           'delivered', now(), now()
      from generate_series(1, 12) g;
    select array_agg(n.id::text order by n.id desc) into v_ids
      from erp.notification n where n.tenant_id = rb.tenant_id and n.app_user_id = rb.admin_user_id;

    -- ── 1. One order, read by the owner and signed in ───────────────────────
    v_step := 'reading the Inbox both ways';
    v_read := public.erp_my_notifications(50);
    set local role authenticated;
    v_signed := public.erp_my_notifications(50);
    v_five := public.erp_my_notifications(5);
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'notices made together come back in one order, by id, read by the owner and signed in alike';
    passed := v_state is null
          and jsonb_array_length(v_read) = 12
          and (select array_agg(x.v ->> 'id' order by x.i) from jsonb_array_elements(v_read) with ordinality x(v, i)) = v_ids
          and v_signed = v_read;
    detail := coalesce(v_state, format('%s notice(s); owner and signed in alike %s', jsonb_array_length(v_read),
                v_signed = v_read));
    return next;

    -- ── 2. A limit takes the first of that order ────────────────────────────
    v_step := 'reading five';
    v_cases := v_cases + 1;
    case_name := 'a limit of five answers the first five of that same order';
    passed := v_state is null
          and jsonb_array_length(v_five) = 5
          and (select array_agg(x.v ->> 'id' order by x.i) from jsonb_array_elements(v_five) with ordinality x(v, i))
              = v_ids[1:5];
    detail := coalesce(v_state, format('%s notice(s)', jsonb_array_length(v_five)));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_NOTICE_ORDER_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code = 'zznor-' || v_tag)
     or exists (select 1 from auth.users u where u.id = a1) then
    raise exception 'CLOVEERP_NOTICE_ORDER_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.notice_order_suite() from public, anon;

comment on function erp_test.notice_order_suite() is
  'Notices made together keep one order (20261007123000): twelve notices sharing a created_at come back by id, the '
  'same read by the owner and signed in, and a limit takes the first of that order.';

create or replace function erp_test.assert_notice_order_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.notice_order_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_NOTICE_ORDER_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The Inbox would reorder notices made together between two reads. Read the case that failed.';
  end if;
  if v_total <> 2 then
    raise exception 'CLOVEERP_NOTICE_ORDER_SUITE_SHRANK: % case(s), expected 2', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('notice order: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_notice_order_suite() from public, anon;

comment on function erp_test.assert_notice_order_suite() is
  'Notices made together come back in one order, however they are read (20261007123000).';

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
select erp.assert_invoker_doors_executable();
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
