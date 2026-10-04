set lock_timeout = '30s';

-- =============================================================================
-- 20261006082000  The dunning worklist works the credit positions out once
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-24). The Finance
-- "Needs chasing" tile, the dunning worklist and the Sales "Customers overdue"
-- tile read public.erp_dunning_worklist(), and it was cancelled at the
-- signed-in limit on every load.
--
-- erp.dunning_worklist() asked erp.credit_position() once for every overdue
-- customer, in a lateral join: a statement per customer, each of them a
-- statement per open order before 20261006081000. It also asked for the
-- organisation in every part of the query.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp_test.dunning_worklist_reference(policy): today's body, word for
--      word, reading erp_test.credit_position_reference(), kept as the answer
--      the new one must give.
--   B. erp.dunning_worklist(policy) keeps its name, its columns and its order.
--      The organisation is read once, the overdue customers once, and their
--      credit positions in one call of erp.credit_positions() for all of them.
--      The level chosen, the hold and its reason are unchanged.
--      public.erp_dunning_worklist() is unchanged.
--   C. erp_test.credit_positions_suite gains case 12: on the demonstration
--      that has traded, the worklist is the same as before, row for row, and
--      no longer asks for credit positions one customer at a time.
--
-- On production: one function is replaced. No table is altered and no row is
-- changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Today's body, kept as the answer
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.dunning_worklist_reference(p_policy_code text default null)
returns table(party_id uuid, party_name text, oldest_days integer, overdue_minor bigint, level_code text,
              level_action text, blocks_trading boolean, on_hold boolean, hold_reason text)
language sql
stable
set search_path = ''
as $reference$
  with pol as (
    select * from erp.dunning_policy
     where tenant_id = erp.current_tenant_id() and status = 'active'
       and (p_policy_code is null or code = p_policy_code)
     order by code limit 1
  ),
  overdue as (
    -- The debt the door counts (20260922340000): an item still owing, with a
    -- due date, aged by it — what erp.credit_position() reads. This used to
    -- take the oldest date of every receivable item past its date, settled
    -- invoices and receipts included, so it chased customers for invoices they
    -- had paid and called them stopped while the door let them trade.
    select si.party_id,
           max(current_date - si.due_date)::integer as days,
           sum(si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0))::bigint as amt
      from erp.subledger_item si
     where si.tenant_id = erp.current_tenant_id()
       and si.control_kind = 'receivable'
       and si.due_date is not null
       and si.due_date < current_date
       and si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) > 0
     group by si.party_id
  )
  select o.party_id, p.name, o.days, o.amt,
         lv.value ->> 'code', lv.value ->> 'action',
         coalesce((lv.value ->> 'blocks_trading')::boolean, false),
         -- What the door actually does about this customer (20260922230000).
         -- blocks_trading is what the letter threatens; this is what
         -- erp.create_document() enforces, and they are not the same
         -- computation. A screen that counts the first and calls it an
         -- enforcement is claiming something no door performs.
         coalesce(cp.on_hold, false),
         cp.reason
    from overdue o
    join erp.party p on p.id = o.party_id
    cross join pol
    -- The most severe level whose threshold the debt has passed. Sending the
    -- first letter to somebody ninety days overdue is how a ledger of
    -- uncollectable debt is built politely.
    cross join lateral (
      select l.value from jsonb_array_elements(pol.levels) l
       where o.days >= (l.value ->> 'after_days')::integer
       order by (l.value ->> 'after_days')::integer desc
       limit 1
    ) lv
    left join lateral erp_test.credit_position_reference(o.party_id) cp on true
   order by o.days desc
$reference$;

revoke all on function erp_test.dunning_worklist_reference(text) from public, anon;

comment on function erp_test.dunning_worklist_reference(text) is
  'erp.dunning_worklist() as it was before 20261006082000, word for word, asking erp_test.credit_position_reference() '
  'for each overdue customer: the worklist the new body must still give (J-24). Read only by '
  'erp_test.credit_positions_suite.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The overdue customers' positions, worked out once
-- ─────────────────────────────────────────────────────────────────────────────

do $guard$
declare
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = 'erp.dunning_worklist(text)'::regprocedure);
begin
  if strpos(v_src, '20261006082000') = 0 and md5(v_src) <> 'e81e0142b3de28146c99d1d8f1098e25' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.dunning_worklist(text) is not the body 20261006082000 expects (md5 %)', md5(v_src);
  end if;
end
$guard$;

create or replace function erp.dunning_worklist(p_policy_code text default null)
returns table(party_id uuid, party_name text, oldest_days integer, overdue_minor bigint, level_code text,
              level_action text, blocks_trading boolean, on_hold boolean, hold_reason text)
language sql
stable
set search_path = ''
as $function$
  -- The organisation is read once, and the overdue customers' credit
  -- positions are worked out in one call for all of them (20261006082000,
  -- J-24), not one statement per customer.
  with t as materialized (select erp.current_tenant_id() as id),
  pol as (
    select * from erp.dunning_policy
     where tenant_id = (select t.id from t) and status = 'active'
       and (p_policy_code is null or code = p_policy_code)
     order by code limit 1
  ),
  overdue as materialized (
    -- The debt the door counts (20260922340000): an item still owing, with a
    -- due date, aged by it — what erp.credit_position() reads. This used to
    -- take the oldest date of every receivable item past its date, settled
    -- invoices and receipts included, so it chased customers for invoices they
    -- had paid and called them stopped while the door let them trade.
    select si.party_id,
           max(current_date - si.due_date)::integer as days,
           sum(si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0))::bigint as amt
      from erp.subledger_item si
     where si.tenant_id = (select t.id from t)
       and si.control_kind = 'receivable'
       and si.due_date is not null
       and si.due_date < current_date
       and si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) > 0
     group by si.party_id
  )
  select o.party_id, p.name, o.days, o.amt,
         lv.value ->> 'code', lv.value ->> 'action',
         coalesce((lv.value ->> 'blocks_trading')::boolean, false),
         -- What the door actually does about this customer (20260922230000).
         -- blocks_trading is what the letter threatens; this is what
         -- erp.create_document() enforces, and they are not the same
         -- computation. A screen that counts the first and calls it an
         -- enforcement is claiming something no door performs.
         coalesce(cp.on_hold, false),
         cp.reason
    from overdue o
    join erp.party p on p.id = o.party_id
    cross join pol
    -- The most severe level whose threshold the debt has passed. Sending the
    -- first letter to somebody ninety days overdue is how a ledger of
    -- uncollectable debt is built politely.
    cross join lateral (
      select l.value from jsonb_array_elements(pol.levels) l
       where o.days >= (l.value ->> 'after_days')::integer
       order by (l.value ->> 'after_days')::integer desc
       limit 1
    ) lv
    left join erp.credit_positions(array(select o2.party_id from overdue o2)) cp on cp.party_id = o.party_id
   order by o.days desc
$function$;

revoke all on function erp.dunning_worklist(text) from public, anon;

comment on function erp.dunning_worklist(text) is
  'Customers with overdue debt, the dunning level their oldest debt has reached, and — since 20260922230000 — whether '
  'the doors are actually holding them, which is a different question from what the level threatens. Their credit '
  'positions are worked out in one call since 20261006082000.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof gains the worklist
-- ─────────────────────────────────────────────────────────────────────────────

do $suite$
declare
  v_sig  constant text := 'erp_test.credit_positions_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_count_old constant text := $o$  c_expected constant integer := 11;
$o$;
  v_count_new constant text := $n$  c_expected constant integer := 12;
$n$;
  v_cases_old constant text := $o$    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
$o$;
  v_cases_new constant text := $n$    -- ── 12. The worklist is the same, worked out once ───────────────────────
    -- (20261006082000) On the demonstration that has traded, every row of
    -- the dunning worklist is what the frozen body gives, and the body asks
    -- for the positions in one call.
    v_step := 'the dunning worklist';
    select count(*) into v_n
      from ((select * from erp.dunning_worklist(null) except all select * from erp_test.dunning_worklist_reference(null))
            union all
            (select * from erp_test.dunning_worklist_reference(null) except all select * from erp.dunning_worklist(null))) z;
    select count(*), count(*) filter (where w.on_hold),
           count(*) filter (where w.hold_reason is distinct from
                                  (select r.reason from erp_test.credit_position_reference(w.party_id) r))
      into v_m, v_k, v_a
      from erp.dunning_worklist(null) w;
    v_ok := (select bool_and(w.oldest_days >= coalesce(w.next_days, w.oldest_days))
               from (select x.oldest_days, lead(x.oldest_days) over () as next_days from erp.dunning_worklist(null) x) w);
    v_differ := (select case when p.prosrc like '%lateral erp.credit_position(%' then 'per customer'
                             when p.prosrc like '%erp.credit_positions(array(%' then 'once' else 'neither' end
                   from pg_catalog.pg_proc p where p.oid = 'erp.dunning_worklist(text)'::regprocedure);
    v_cases := v_cases + 1;
    case_name := 'the dunning worklist is the same as before, row for row, and works the credit positions out once';
    passed := v_n = 0 and v_m >= 1 and v_k >= 1 and v_a = 0 and v_ok and v_differ = 'once';
    detail := format('%s row(s), %s held, %s differing from before, %s hold reason(s) differing; oldest first: %s; positions asked %s',
                     v_m, v_k, v_n, v_a, v_ok, v_differ);
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
$n$;
begin
  if strpos(v_src, '20261006082000') > 0 then
    raise notice '% already has case 12; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'ef4fd8d129c0e13653294bd297204929' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006082000 expects (md5 %)', v_sig, md5(v_src);
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
  'counts the same, and no routine adds up orders one at a time; since 20261006082000 the dunning worklist is the '
  'same, row for row, with the positions worked out once.';

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
  if v_total <> 12 then
    raise exception 'CLOVEERP_CREDIT_POSITIONS_SUITE_SHRANK: % case(s), expected 12', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('credit positions: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_credit_positions_suite() from public, anon;

comment on function erp_test.assert_credit_positions_suite() is
  'The credit position read for many customers at once gives today''s figures, the readers read it, and the dunning '
  'worklist works it out once (20261006080000, 20261006081000, 20261006082000).';

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
