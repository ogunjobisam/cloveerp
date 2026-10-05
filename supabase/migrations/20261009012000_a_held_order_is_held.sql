set lock_timeout = '30s';

-- =============================================================================
-- 20261009012000  A held order is held
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-79, J-80).
--
-- J-79. The Sales screen's "On credit hold" tile counted the release
-- sequence's lines whose customer's credit status was not 'ok', so a customer
-- merely on watch read as held. On live the demonstration's customers were ten
-- 'ok', two 'watch' and none blocked: the tile said orders were held and none
-- was. What actually holds an order is erp.check_release_to_fulfilment: the
-- customer's credit position on hold (blocked, over the limit, or debt overdue
-- beyond the policy's window) and the order not released. And Release a credit
-- hold offered every confirmed order by number and raw state, held or not,
-- with no customer.
--
-- J-80. The release sequence ranked and answered the line's own required date
-- only. An order whose lines carry no date of their own, which is most of
-- them, showed no date and sorted last, though the order says when it is
-- wanted.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_release_sequence answers, on each line, the order's
--      document_id and 'on_hold': the customer's position from
--      erp.credit_positions (the set-based credit position, worked out once
--      for every customer with a line here) on hold, and the order not
--      released by somebody who may release credit holds. Its credit_status is
--      the one in the customer's terms in force, read there too, so a customer
--      with terms that have ended or changed no longer reads twice. Its
--      required_date is the line's own, or else the order's, and the ranking
--      reads the same date.
--   B. The order to cash cycle's register row: five actions, not four, because
--      the Sales order step now offers Release a credit hold beside picking and
--      delivering, with the order already chosen. Still four steps, each with
--      its list.
--   C. erp_test.held_orders_suite, which holds, releases and watches orders and
--      reads them as the tile and the Release picker do, and holds the answer
--      against erp.check_release_to_fulfilment.
--
-- The screen's half is in src/lib/modules.tsx (the tile counts on_hold) and
-- src/routes/sales/index.tsx (Release a credit hold lists the held orders by
-- number and customer, and is on the Sales order step).
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- Who may release, and what releasing does: erp.release_credit_hold still
-- authorises sales.credit_release and records who released and why, and
-- picking and delivering still ask erp.check_release_to_fulfilment, which
-- also lets through an order whose own credit approval covers what is owed
-- now. The release sequence does not repeat that approval reading; an order so
-- approved reads held here until it is released, which is the safe side.
--
-- On production: one function is replaced, one row of erp_meta.flow_budget is
-- rewritten and a test function added. No table is altered and no row of any
-- organisation is touched.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The release sequence says which orders are held
-- ─────────────────────────────────────────────────────────────────────────────

do $guard$
declare
  v_sig constant text := 'public.erp_release_sequence(uuid,integer)';
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
begin
  if strpos(v_src, '20261009012000') > 0 then
    raise notice '% already says which orders are held; replaced with the same body', v_sig;
  elsif md5(v_src) <> 'fd604dea994f219f7e68e8f7816c17b5' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261009012000 expects (md5 %)', v_sig, md5(v_src);
  end if;
end
$guard$;

create or replace function public.erp_release_sequence(p_site_id uuid default null, p_limit integer default 100)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with lines as materialized (
    select dl.id as line_id, dl.line_no, d.id as document_id, d.document_number, d.party_id,
           s.code as order_state,
           p.name as customer, i.code as item, i.name as item_name,
           dl.quantity, dl.quantity_fulfilled,
           -- The line's own date, or else the order's (20261009012000): most
           -- lines carry none, and the order still says when it is wanted.
           coalesce(dl.required_date, d.required_date) as required_date,
           dl.quantity * dl.unit_price_minor as value_minor,
           d.attributes ? 'credit_released_by' as released,
           coalesce(av.available, 0) as available
      from erp.document_line dl
      join erp.document d on d.tenant_id = dl.tenant_id and d.id = dl.document_id
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      -- An order that can still be fulfilled: confirmed, or being picked.
      -- A draft is not agreed, one waiting on approval is not approved, and
      -- one despatched, invoiced, closed or cancelled has nothing to release.
      join erp.object_state os
        on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      join erp.state s on s.id = os.current_state_id
      join erp.item i on i.tenant_id = dl.tenant_id and i.id = dl.item_id
      left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
      left join lateral (
        select sum(a.available) as available
          from erp.stock_availability a
         where a.tenant_id = dl.tenant_id and a.item_id = dl.item_id
           and (d.site_id is null or a.site_id = d.site_id)) av on true
     where dl.tenant_id = erp.current_tenant_id()
       and dt.base_type_code = 'sales_order'
       and s.code in ('confirmed', 'picking', 'partially_despatched')
       and coalesce(dl.is_cancelled, false) = false
       and coalesce(d.is_cancelled, false) = false
       and dl.quantity > coalesce(dl.quantity_fulfilled, 0)
       -- Nor a line the sales policy reads delivered (20260924000000).
       and not erp.sales_line_is_delivered(dl.id)
       and (p_site_id is null or d.site_id = p_site_id)
  ),
  -- Each customer's credit position, worked out once for every customer with
  -- a line here (20261009012000). On hold is what erp.check_release_to_fulfilment
  -- stops an order for: blocked, over the limit, or debt overdue beyond the
  -- policy's window. A customer with no terms in force has no position and is
  -- not held, as picking reads it.
  positions as materialized (
    select cp.party_id, cp.credit_status, cp.on_hold
      from erp.credit_positions(array(select distinct l.party_id from lines l where l.party_id is not null)) cp
  ),
  ranked as (
    select row_number() over (
             order by l.required_date nulls last,
                      case when coalesce(cp.credit_status, 'ok') = 'ok' then 0 else 1 end,
                      l.value_minor desc,
                      l.document_number, l.line_no)::integer as release_rank,
           l.line_id, l.document_id, l.document_number, l.order_state, l.customer,
           l.item, l.item_name, l.quantity, l.quantity_fulfilled, l.required_date,
           coalesce(cp.credit_status, 'ok') as credit_status,
           -- Held until somebody who may release credit holds releases it.
           coalesce(cp.on_hold, false) and not l.released as on_hold,
           l.available
      from lines l
      left join positions cp on cp.party_id = l.party_id
  )
  select coalesce(jsonb_agg(q.x order by q.release_rank), '[]'::jsonb) from (
    select r.release_rank, jsonb_build_object(
             'rank', r.release_rank,
             'line_id', r.line_id, 'document_id', r.document_id, 'document_number', r.document_number,
             'order_state', r.order_state,
             'customer', r.customer, 'item', r.item, 'item_name', r.item_name,
             'quantity', r.quantity, 'quantity_fulfilled', r.quantity_fulfilled,
             'required_date', r.required_date,
             'credit_status', r.credit_status,
             'on_hold', r.on_hold,
             'available', r.available,
             'can_ship_in_full', r.available >= (r.quantity - coalesce(r.quantity_fulfilled, 0))) as x
      from ranked r
     order by r.release_rank
     limit greatest(coalesce(p_limit, 100), 1)
  ) q
$$;

revoke all on function public.erp_release_sequence(uuid, integer) from public, anon;

comment on function public.erp_release_sequence(uuid, integer) is
  'Lines of sales orders that are confirmed or being picked and not delivered in full, in the order they should be '
  'released: required date (the line''s, or else the order''s), then credit standing, then value. Each line names '
  'its order and says whether the order is held on credit: the customer''s credit position on hold and the order '
  'not released (20261009012000). The first p_limit in that order. Reads under row security as the caller.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Order to cash is five actions over four steps
-- ─────────────────────────────────────────────────────────────────────────────

do $budget$
declare
  c_rationale constant text :=
    'The five actions over four steps are what the Sales screen''s strip draws: converting a quotation, '
    'promising a date, picking the order, releasing it from a credit hold and creating its delivery, the last '
    'four on the Sales order step with the order already chosen (20261009010000, 20261009012000). Find a price '
    'is in the screen''s Actions sheet, and applying cash is Financials'' Cash in step. Most of order to cash is '
    'reached from the document screen rather than the strip. The cycle itself is walked by '
    'erp_test.step_budget_suite at seven presses by four people, from a quotation to a filed invoice paid and a '
    'closed order, with the six moves nobody pressed made by what happened (20260924100000).';
  v_row record;
begin
  select b.budget, b.decision_steps, b.stages, b.stages_without_a_list, b.rationale into v_row
    from erp_meta.flow_budget b where b.flow_code = 'o2c';
  if not found then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the order to cash cycle has no budget; 20261009012000 rewrites it';
  end if;
  if strpos(v_row.rationale, '20261009012000') > 0 then
    raise notice 'the order to cash cycle already reads five actions; left as it is';
    return;
  end if;
  if (v_row.budget, v_row.decision_steps, v_row.stages, v_row.stages_without_a_list) <> (4, 4, 4, 0)
     or strpos(v_row.rationale, '20261009010000') = 0 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the order to cash cycle''s budget is not the one 20261009012000 expects (%/%/%/%, md5 %)',
      v_row.budget, v_row.decision_steps, v_row.stages, v_row.stages_without_a_list, md5(v_row.rationale);
  end if;

  -- Raised in the open, with the reason beside it: Release a credit hold is a
  -- verb of the Sales order step now.
  update erp_meta.flow_budget
     set budget = 5, decision_steps = 5, rationale = c_rationale
   where flow_code = 'o2c';
end
$budget$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.held_orders_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  v_site uuid; v_uom uuid; v_item uuid; v_ccy char(3);
  c_ok uuid; c_watch uuid; c_blocked uuid; c_released uuid; c_over uuid; c_none uuid;
  o_ok uuid; o_watch uuid; o_blocked uuid; o_released uuid; o_over uuid; o_none uuid; o_later uuid;
  v_code text; v_party uuid; v_order uuid; v_n integer := 0;
  v_seq jsonb; v_held jsonb; v_check text; v_mismatch text := '';
  v_dated text; v_later text; v_rank_dated integer; v_rank_later integer;
begin
  begin
    -- ── The fixture: customers in each standing, each with a confirmed order ──
    v_step := 'an organisation configured as the demonstration is';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzhos-' || v_tag, 'Held Orders Suite',
      'admin@zzhos-' || v_tag || '.test', 'Held Orders Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzhos-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    v_step := 'its site, unit and product';
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = rb.entity_id order by s.code limit 1;
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base and u.uom_class = 'quantity' and u.status = 'active'
     order by u.code limit 1;
    select e.base_currency into v_ccy from erp.entity e where e.tenant_id = rb.tenant_id and e.id = rb.entity_id;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZHOWID', 'Held Orders Widget', v_uom, 'active') returning id into v_item;

    -- Six customers. All but the last have terms, every one clear when its
    -- order is confirmed; their standing changes afterwards.
    v_step := 'six customers, five with terms';
    foreach v_code in array array['OK', 'WATCH', 'BLOCKED', 'RELEASED', 'OVER', 'NONE'] loop
      v_step := 'the customer ' || v_code || ' and their order';
      insert into erp.party (tenant_id, code, name, status)
      values (rb.tenant_id, 'ZHO' || v_code, 'Held Orders ' || initcap(v_code), 'active') returning id into v_party;
      insert into erp.party_role (tenant_id, party_id, role_kind, status)
      values (rb.tenant_id, v_party, 'customer', 'active');
      if v_code <> 'NONE' then
        insert into erp.party_role_terms (
          tenant_id, party_role_id, entity_id, currency, credit_limit_minor, credit_status, is_blocked, valid_from)
        select rb.tenant_id, pr.id, rb.entity_id, v_ccy, null, 'ok', false, current_date - 1
          from erp.party_role pr
         where pr.tenant_id = rb.tenant_id and pr.party_id = v_party and pr.role_kind = 'customer';
      end if;
      v_n := v_n + 1;
      -- Every order but the first is wanted in ten days, said on the order and
      -- on none of its lines. The first is wanted in three, said the same way.
      v_order := erp.open_document('sales_order', v_party, null, v_site, null,
                                   current_date + case when v_n = 1 then 3 else 10 end);
      perform erp.add_document_line(v_order, v_item, 5, 1000 * v_n, 'the held orders suite');
      perform erp.transition_document(v_order, 'submit', 'the held orders suite');
      perform erp_test.approve_document(v_order, 'the held orders suite');
      case v_code
        when 'OK' then c_ok := v_party; o_ok := v_order;
        when 'WATCH' then c_watch := v_party; o_watch := v_order;
        when 'BLOCKED' then c_blocked := v_party; o_blocked := v_order;
        when 'RELEASED' then c_released := v_party; o_released := v_order;
        when 'OVER' then c_over := v_party; o_over := v_order;
        else c_none := v_party; o_none := v_order;
      end case;
    end loop;

    -- A second order for the first customer, its line dated a week out.
    v_step := 'an order whose line carries a date of its own';
    o_later := erp.open_document('sales_order', c_ok, null, v_site);
    perform erp.add_document_line(o_later, v_item, 1, 99000, 'the held orders suite', current_date + 7);
    perform erp.transition_document(o_later, 'submit', 'the held orders suite');
    perform erp_test.approve_document(o_later, 'the held orders suite');

    v_step := 'one customer watched, two blocked, one over the limit';
    update erp.party_role_terms t set credit_status = 'watch'
      from erp.party_role pr
     where pr.id = t.party_role_id and t.tenant_id = rb.tenant_id and pr.party_id = c_watch;
    update erp.party_role_terms t set is_blocked = true, block_reason = 'Disputed invoices'
      from erp.party_role pr
     where pr.id = t.party_role_id and t.tenant_id = rb.tenant_id and pr.party_id in (c_blocked, c_released);
    update erp.party_role_terms t set credit_limit_minor = 1
      from erp.party_role pr
     where pr.id = t.party_role_id and t.tenant_id = rb.tenant_id and pr.party_id = c_over;

    v_step := 'one blocked customer''s order released';
    perform erp.release_credit_hold(o_released, 'the held orders suite: paid by card on the phone');

    v_step := 'the release sequence read as the tile and the Release picker read it';
    v_seq := public.erp_release_sequence(null, 500);
    select coalesce(jsonb_agg(distinct l ->> 'document_id'), '[]'::jsonb) into v_held
      from jsonb_array_elements(v_seq) l where (l ->> 'on_hold')::boolean;

    -- ── 1. Blocked and over the limit are held ──────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the order of a customer on credit hold, and of one over their limit, reads held, by its order and with its customer';
    passed := v_state is null
          and v_held @> jsonb_build_array(o_blocked::text, o_over::text)
          and exists (select 1 from jsonb_array_elements(v_seq) l
                       where l ->> 'document_id' = o_blocked::text and (l ->> 'on_hold')::boolean
                         and l ->> 'customer' = 'Held Orders Blocked'
                         and l ->> 'document_number' = (select d.document_number from erp.document d where d.id = o_blocked));
    detail := coalesce(v_state, format('held %s', v_held));
    return next;

    -- ── 2. Watch is not held ────────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'a customer on watch is not held: their order reads watch, and not held';
    passed := v_state is null
          and exists (select 1 from jsonb_array_elements(v_seq) l
                       where l ->> 'document_id' = o_watch::text and l ->> 'credit_status' = 'watch'
                         and not (l ->> 'on_hold')::boolean)
          and not v_held ? o_watch::text;
    detail := coalesce(v_state, format('held %s', v_held));
    return next;

    -- ── 3. Released, clear and without terms are not held ───────────────────
    v_cases := v_cases + 1;
    case_name := 'an order released from its hold, a customer within terms and one with no terms are not held, and exactly two orders are';
    passed := v_state is null
          and not v_held ?| array[o_released::text, o_ok::text, o_none::text, o_later::text]
          and jsonb_array_length(v_held) = 2;
    detail := coalesce(v_state, format('held %s', v_held));
    return next;

    -- ── 4. The sequence agrees with what picking refuses ────────────────────
    v_step := 'each order asked as picking asks';
    foreach v_order in array array[o_ok, o_watch, o_blocked, o_released, o_over, o_none, o_later] loop
      begin
        v_check := erp.check_release_to_fulfilment(v_order);
      exception when others then
        v_check := case when sqlerrm like 'CLOVEERP_CREDIT_HOLD:%' then 'held' else left(sqlerrm, 120) end;
      end;
      if (v_check = 'held') <> (v_held ? v_order::text) then
        v_mismatch := v_mismatch || format('%s: picking says %s; ', v_order, v_check);
      end if;
    end loop;
    v_cases := v_cases + 1;
    case_name := 'an order reads held in the release sequence exactly when picking it is refused for credit';
    passed := v_state is null and v_mismatch = '';
    detail := coalesce(v_state, nullif(v_mismatch, ''), 'agreed on all seven orders');
    return next;

    -- ── 5. An order dated on its header is wanted by that date ──────────────
    v_step := 'the dates read';
    select l ->> 'required_date', (l ->> 'rank')::integer into v_dated, v_rank_dated
      from jsonb_array_elements(v_seq) l where l ->> 'document_id' = o_ok::text;
    select l ->> 'required_date', (l ->> 'rank')::integer into v_later, v_rank_later
      from jsonb_array_elements(v_seq) l where l ->> 'document_id' = o_later::text;
    v_cases := v_cases + 1;
    case_name := 'a line with no date of its own is wanted by its order''s date and is ranked by it, ahead of a line dated later and before every undated order';
    passed := v_state is null
          and v_dated::date = current_date + 3
          and v_later::date = current_date + 7
          and v_rank_dated = 1 and v_rank_later = 2
          and not exists (select 1 from jsonb_array_elements(v_seq) l where l ->> 'required_date' is null);
    detail := coalesce(v_state, format('header-dated %s at %s; line-dated %s at %s', v_dated, v_rank_dated, v_later, v_rank_later));
    return next;

    -- ── 6. The strip's budget ───────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'order to cash is five actions over four steps, every one keeping a list';
    passed := v_state is null
          and exists (select 1 from erp_meta.flow_budget b
                       where b.flow_code = 'o2c' and b.budget = 5 and b.decision_steps = 5
                         and b.stages = 4 and b.stages_without_a_list = 0);
    detail := coalesce(v_state, 'o2c 5/5/4/0');
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzhos-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1)
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzhos rolled back with its customers and orders');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_HELD_ORDERS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
end;
$$;

revoke all on function erp_test.held_orders_suite() from public, anon;

comment on function erp_test.held_orders_suite() is
  'A held order is held (20261009012000): in the release sequence, the order of a customer on credit hold or over '
  'their limit reads held, by order and customer; one on watch, one released, one within terms and one with no '
  'terms do not; held agrees with what erp.check_release_to_fulfilment refuses; a line with no date of its own is '
  'wanted and ranked by its order''s date; and order to cash is five actions over four steps.';

create or replace function erp_test.assert_held_orders_suite()
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
    from erp_test.held_orders_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_HELD_ORDERS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The Sales screen would count or offer held orders other than as picking holds them. Read the case that failed.';
  end if;
  if v_total <> 7 then
    raise exception 'CLOVEERP_HELD_ORDERS_SUITE_SHRANK: % case(s), expected 7', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('held orders: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_held_orders_suite() from public, anon;

comment on function erp_test.assert_held_orders_suite() is
  'The release sequence says which orders are held on credit as picking holds them, and when each is wanted '
  '(20261009012000).';

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
