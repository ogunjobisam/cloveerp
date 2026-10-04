set lock_timeout = '30s';

-- =============================================================================
-- 20261006081000  The credit position and the approval's order book are read
--                 in one statement
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-24). A customer's
-- credit position took 1.6 s on a quiet database, one statement per open
-- sales order. The same loop over orders runs inside every approval of a
-- document (erp.document_transition_context), which is read by
-- erp_available_transitions, transition, convert, create, pick and both
-- creates from an order; those presses were given thirty seconds as a stopgap
-- (20261005600000).
--
-- 20261006080000 added the set-based reads and proved them against today's
-- bodies, frozen word for word, on a demonstration that has traded. This
-- migration switches the readers over.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.credit_position(party) keeps its name, its columns and its ten
--      callers, and reads erp.credit_positions() for the one customer.
--   B. erp.sales_order_uninvoiced_minor(order) reads
--      erp.sales_orders_uninvoiced() for the one order.
--   C. erp.document_transition_context(document, transition), edited in
--      place: what the customer's other open sales orders have not yet
--      invoiced is read in one statement instead of one per order. The
--      orders it reads, and everything else in the context, are unchanged.
--   D. erp_test.credit_positions_suite gains two cases (10 and 11): every
--      document's approval context counts what the frozen bodies count, and
--      no routine adds up orders one at a time any more.
--
-- On production: three functions are replaced and one is edited in place. No
-- table is altered and no row is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. One customer's credit position, from the set
-- ─────────────────────────────────────────────────────────────────────────────

-- The two bodies replaced whole below are the ones 20261006080000 froze as
-- the answer; anything else in their place is somebody else's change.
do $guard$
declare
  v_position text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = 'erp.credit_position(uuid)'::regprocedure);
  v_order    text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = 'erp.sales_order_uninvoiced_minor(uuid)'::regprocedure);
begin
  if strpos(v_position, '20261006081000') = 0 and md5(v_position) <> 'f642f943606f463229b06b6ea38e9372' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.credit_position(uuid) is not the body 20261006081000 expects (md5 %)', md5(v_position);
  end if;
  if strpos(v_order, '20261006081000') = 0 and md5(v_order) <> '62d7b644dc8f5cbcec0e37dd5e74da5b' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.sales_order_uninvoiced_minor(uuid) is not the body 20261006081000 expects (md5 %)', md5(v_order);
  end if;
end
$guard$;

create or replace function erp.credit_position(p_party_id uuid)
returns table(credit_limit_minor bigint, exposure_minor bigint, headroom_minor bigint, credit_status text,
              is_blocked boolean, on_hold boolean, reason text)
language sql
stable
set search_path = ''
as $function$
  -- Read from erp.credit_positions() for the one customer (20261006081000):
  -- the same terms, policy, exposure, verdict and reason, in one statement
  -- instead of one per open order.
  select c.credit_limit_minor, c.exposure_minor, c.headroom_minor, c.credit_status, c.is_blocked, c.on_hold, c.reason
    from erp.credit_positions(array[p_party_id]) c
$function$;

revoke all on function erp.credit_position(uuid) from public, anon;

comment on function erp.credit_position(uuid) is
  'One customer''s credit position: the limit of the terms in force, what is on order and not invoiced plus what is '
  'owed, the headroom, and whether supply stops and why. Read from erp.credit_positions() since 20261006081000.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. One order's uninvoiced value, from the set
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.sales_order_uninvoiced_minor(p_order_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $function$
  -- The order's value less the value of the invoices it has raised, never
  -- below nought: what the customer has on order and does not yet owe. Read
  -- from erp.sales_orders_uninvoiced() since 20261006081000; an id that is
  -- not a document of the organisation is worth nought, as before.
  select coalesce((select u.uninvoiced_minor from erp.sales_orders_uninvoiced(array[p_order_id]) u), 0)::bigint
$function$;

revoke all on function erp.sales_order_uninvoiced_minor(uuid) from public, anon;

comment on function erp.sales_order_uninvoiced_minor(uuid) is
  'What one order has on order and not yet invoiced: its value less the issued invoices raised for its deliveries, '
  'never below nought. Read from erp.sales_orders_uninvoiced() since 20261006081000.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The approval reads the customer's other orders in one statement
-- ─────────────────────────────────────────────────────────────────────────────

do $context$
declare
  v_sig  constant text := 'erp.document_transition_context(uuid,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  select coalesce(sum(erp.sales_order_uninvoiced_minor(d2.id)), 0) into v_exposure
    from erp.document d2
    join erp.document_type dt2 on dt2.tenant_id = d2.tenant_id and dt2.id = d2.document_type_id
    join erp.object_state os2 on os2.tenant_id = d2.tenant_id
                             and os2.object_type = 'document' and os2.object_id = d2.id
    join erp.state s2 on s2.id = os2.current_state_id
   where d2.tenant_id = v_tenant
     and d2.party_id = d.party_id
     and dt2.base_type_code = 'sales_order'
     and s2.is_committed and not s2.is_terminal
     and d2.id <> p_document_id
     and not d2.is_cancelled;
$o$;
  v_new  constant text := $n$  -- The orders are read in one statement (20261006081000, J-24), not one
  -- statement per order.
  select coalesce(sum(u.uninvoiced_minor), 0) into v_exposure
    from erp.sales_orders_uninvoiced(array(
      select d2.id
        from erp.document d2
        join erp.document_type dt2 on dt2.tenant_id = d2.tenant_id and dt2.id = d2.document_type_id
        join erp.object_state os2 on os2.tenant_id = d2.tenant_id
                                 and os2.object_type = 'document' and os2.object_id = d2.id
        join erp.state s2 on s2.id = os2.current_state_id
       where d2.tenant_id = v_tenant
         and d2.party_id = d.party_id
         and dt2.base_type_code = 'sales_order'
         and s2.is_committed and not s2.is_terminal
         and d2.id <> p_document_id
         and not d2.is_cancelled)) u;
$n$;
begin
  if strpos(v_src, '20261006081000') > 0 then
    raise notice '% already reads the orders in one statement; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '8cc974cf7f3d12ea63ff445af1598186' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006081000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % exposure anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$context$;

comment on function erp.document_transition_context(uuid, text) is
  'What an approval rule reads about a document: its type, number, value, currency, party and company, the largest '
  'discount, the customer''s credit limit, what they owe and what they would owe with this document, and for a '
  'transfer or adjustment its value at cost. The customer''s other open orders are read in one statement since '
  '20261006081000.';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof gains the approval and the absence of the loop
-- ─────────────────────────────────────────────────────────────────────────────

do $suite$
declare
  v_sig  constant text := 'erp_test.credit_positions_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_count_old constant text := $o$  c_expected constant integer := 9;
$o$;
  v_count_new constant text := $n$  c_expected constant integer := 11;
$n$;
  v_cases_old constant text := $o$    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
$o$;
  v_cases_new constant text := $n$    -- ── 10. The approval counts what the frozen bodies count ────────────────
    -- (20261006081000) For every document of the demonstration: what the
    -- customer owes, what their other open sales orders have not invoiced and
    -- what this one has not, as erp.document_transition_context() reads it.
    v_step := 'every document''s approval context';
    select count(*),
           count(*) filter (where (x.ctx ->> 'exposure_after_minor')::bigint is distinct from x.expected),
           string_agg(x.document_number, ', ' order by x.document_number)
             filter (where (x.ctx ->> 'exposure_after_minor')::bigint is distinct from x.expected),
           count(*) filter (where x.dt_code = 'sales_order' and x.expected > x.owed),
           max((x.ctx ->> 'exposure_after_minor')::bigint) filter (where x.id = (v_fx ->> 'draft_order')::uuid),
           max(x.expected) filter (where x.id = (v_fx ->> 'draft_order')::uuid)
      into v_n, v_m, v_differ, v_k, v_a, v_b
      from (select d.id, d.document_number, dt.base_type_code as dt_code,
                   erp.document_transition_context(d.id, null) as ctx,
                   coalesce((select sum(si.debit_minor - si.credit_minor)
                               from erp.subledger_item si
                              where si.tenant_id = v_tenant and si.party_id = d.party_id
                                and si.control_kind = 'receivable'), 0) as owed,
                   coalesce((select sum(si.debit_minor - si.credit_minor)
                               from erp.subledger_item si
                              where si.tenant_id = v_tenant and si.party_id = d.party_id
                                and si.control_kind = 'receivable'), 0)
                   + coalesce((select sum(erp_test.sales_order_uninvoiced_reference(d2.id))
                                 from erp.document d2
                                 join erp.document_type dt2 on dt2.tenant_id = d2.tenant_id and dt2.id = d2.document_type_id
                                 join erp.object_state os2 on os2.tenant_id = d2.tenant_id
                                                          and os2.object_type = 'document' and os2.object_id = d2.id
                                 join erp.state s2 on s2.id = os2.current_state_id
                                where d2.tenant_id = v_tenant and d2.party_id = d.party_id
                                  and dt2.base_type_code = 'sales_order'
                                  and s2.is_committed and not s2.is_terminal
                                  and d2.id <> d.id and not d2.is_cancelled), 0)
                   + erp_test.sales_order_uninvoiced_reference(d.id) as expected
              from erp.document d
              join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
             where d.tenant_id = v_tenant) x;
    v_cases := v_cases + 1;
    case_name := 'every document''s approval counts what the customer owes and has on order as before';
    passed := v_m = 0 and v_n >= 100 and v_k >= 5 and v_a = v_b
          and v_b >= 2500 + erp_test.sales_order_uninvoiced_reference((v_fx ->> 'part_order')::uuid);
    detail := format('%s document(s), %s differing (%s); %s sales order(s) with orders counted; the draft order reads %s (before: %s)',
                     v_n, v_m, coalesce(v_differ, 'none'), v_k, v_a, v_b);
    return next;

    -- ── 11. Nothing adds up orders one at a time ───────────────────────────
    v_step := 'the routines that add up orders';
    select string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text)
      into v_differ
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'public')
       and p.prosrc like '%sum(erp.sales_order_uninvoiced_minor(%';
    v_ok := (select p.prosrc like '%erp.credit_positions(array[p_party_id])%'
               from pg_catalog.pg_proc p where p.oid = 'erp.credit_position(uuid)'::regprocedure)
        and (select p.prosrc like '%erp.sales_orders_uninvoiced(array[p_order_id])%'
               from pg_catalog.pg_proc p where p.oid = 'erp.sales_order_uninvoiced_minor(uuid)'::regprocedure)
        and (select p.prosrc like '%erp.sales_orders_uninvoiced(array(%'
               from pg_catalog.pg_proc p where p.oid = 'erp.document_transition_context(uuid,text)'::regprocedure);
    v_cases := v_cases + 1;
    case_name := 'no routine adds up a customer''s orders one statement at a time';
    passed := v_differ is null and v_ok;
    detail := format('summing one order at a time: %s; the credit position, the order and the approval read the set: %s',
                     coalesce(v_differ, 'none'), v_ok);
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
$n$;
begin
  if strpos(v_src, '20261006081000') > 0 then
    raise notice '% already has cases 10 and 11; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '61bad96d4d3c1d1e8cbddda18e96e188' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006081000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_count_old, ''))) / length(v_count_old) <> 1
     or (length(v_def) - length(replace(v_def, v_cases_old, ''))) / length(v_cases_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % count or case anchor found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_count_old, v_count_new), v_cases_old, v_cases_new);
end
$suite$;

comment on function erp_test.credit_positions_suite() is
  'A credit position can be worked out for many customers at once (20261006080000, J-24): on a demonstration that '
  'has traded, the set-based reads give the figures today''s bodies gave for every customer and every document, and '
  'each rule of the position holds on a stated figure. Since 20261006081000 every document''s approval context '
  'counts the same, and no routine adds up orders one at a time.';

create or replace function erp_test.assert_credit_positions_suite()
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
    from erp_test.credit_positions_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_CREDIT_POSITIONS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A credit position would say otherwise than before, and an order could ship or stop that should not. Read the case that failed.';
  end if;
  if v_total <> 11 then
    raise exception 'CLOVEERP_CREDIT_POSITIONS_SUITE_SHRANK: % case(s), expected 11', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('credit positions: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_credit_positions_suite() from public, anon;

comment on function erp_test.assert_credit_positions_suite() is
  'The credit position read for many customers at once gives today''s figures, and the readers read it '
  '(20261006080000, 20261006081000).';

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
