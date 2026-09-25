set lock_timeout = '30s';

-- =============================================================================
-- 20260925210000  Backflush takes only what is free
-- -----------------------------------------------------------------------------
-- PR8, M5, the second migration: what the review of erp.backflush_works_order()
-- (20260925200000) found, put right in the same pull request.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
--   * An item on two lines of a bill was measured line by line, and an issue
--     by hand was credited to whichever line the database found first. Twenty
--     and thirty required, thirty issued by hand to the first line, and the
--     receipt backflushed thirty more to the second: sixty consumed for fifty.
--   * An expired batch was consumed first, because it expires first, and then
--     lent its date to the output it went into.
--   * A blocked location was drawn on, and so was stock committed to a pick,
--     leaving the pick pointed at an empty shelf while free stock sat
--     elsewhere.
--   * Two orders drawing on one balance read it without a lock.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   * What is due and what is issued are summed over the item's lines, and an
--     issue is credited to the first line still short, then the first.
--   * Only free stock is drawn on: in an active, unblocked location, not
--     expired at the site's today, less what picks have committed. Short of
--     it, the receipt is refused and says what was left out; it does not take
--     a pick's stock.
--   * The balances drawn on are locked, and items are taken in one order, so
--     two orders queue rather than overdraw or deadlock.
-- =============================================================================

create or replace function erp.backflush_works_order(p_works_order_id uuid, p_completed numeric)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  wo        erp.works_order%rowtype;
  v_company uuid;
  v_custody uuid;
  v_today   date;
  r         record;
  b         record;
  v_left    numeric;
  v_take    numeric;
  v_held    numeric;
  v_n       integer := 0;
begin
  select * into wo from erp.works_order where tenant_id = v_tenant and id = p_works_order_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_WORKS_ORDER: %', p_works_order_id using errcode = '23503';
  end if;
  if coalesce(wo.quantity, 0) <= 0 then
    return 0;
  end if;

  -- The stock a movement of the order's company would move: its own, held by
  -- whoever keeps the site.
  select e.party_id into v_company from erp.entity e where e.id = wo.entity_id;
  v_custody := coalesce((select s.operator_party_id from erp.site s where s.id = wo.site_id), v_company);
  v_today := erp.local_today(wo.site_id);

  -- By item, over every line that asks for it; in one order, so two orders
  -- lock the same balances the same way round.
  for r in
    select c.item_id, sum(c.required_quantity) as required, sum(c.issued_quantity) as issued,
           least(coalesce(min(u.decimals), 6), 6) as decimals,
           min(i.code) as item_code, bool_or(i.is_batch_controlled) as is_batch_controlled,
           bool_or(i.is_fefo) as is_fefo
      from erp.works_order_component c
      join erp.item i on i.id = c.item_id
      left join erp.uom u on u.id = c.uom_id
     where c.tenant_id = v_tenant and c.works_order_id = p_works_order_id
     group by c.item_id
     order by c.item_id
  loop
    v_left := round(r.required * p_completed / wo.quantity, r.decimals) - r.issued;
    continue when v_left <= 0;

    for b in
      select bal.id, bal.location_id, bal.batch_id,
             bal.quantity - coalesce(cm.committed, 0) as free
        from erp.stock_balance bal
        join erp.location l on l.id = bal.location_id
        left join erp.batch bt on bt.id = bal.batch_id
        left join lateral (
          select sum(al2.quantity) as committed
            from erp.allocation_line al2
            join erp.allocation a2 on a2.tenant_id = al2.tenant_id and a2.id = al2.allocation_id
           where al2.tenant_id = bal.tenant_id and al2.location_id = bal.location_id
             and al2.batch_id is not distinct from bal.batch_id
             and al2.stock_status = bal.stock_status
             and a2.item_id = bal.item_id
             and a2.status in ('committed', 'picked') and al2.status in ('committed', 'picked')) cm on true
       where bal.tenant_id = v_tenant and bal.item_id = r.item_id and bal.site_id = wo.site_id
         and bal.stock_status = 'available' and bal.quantity > 0
         and bal.owner_party_id = v_company and bal.custody_party_id = v_custody
         and bal.serial_id is null and bal.container_id is null
         and (not r.is_batch_controlled or bal.batch_id is not null)
         and l.status = 'active' and not l.is_blocked
         and (bt.expires_on is null or bt.expires_on >= v_today)
         and bal.quantity - coalesce(cm.committed, 0) > 0
       order by case when r.is_fefo then bt.expires_on end nulls last,
                bt.manufactured_on nulls last,
                bal.first_received_at nulls last,
                bal.quantity desc, bal.id
       for update of bal
    loop
      exit when v_left <= 0;
      v_take := least(v_left, b.free);
      perform erp.issue_to_works_order(p_works_order_id, r.item_id, v_take, b.batch_id, b.location_id);
      v_left := v_left - v_take;
      v_n := v_n + 1;
    end loop;

    if v_left > 0 then
      select coalesce(sum(bal.quantity), 0) into v_held
        from erp.stock_balance bal
       where bal.tenant_id = v_tenant and bal.item_id = r.item_id and bal.site_id = wo.site_id
         and bal.stock_status = 'available';
      raise exception 'CLOVEERP_NO_COMPONENT_STOCK: % needs % more of % than is free at this site; % is held there, and what is expired, blocked, committed to a pick, in a container or serial-numbered is not taken',
        wo.order_number, v_left, r.item_code, v_held
        using errcode = '23514',
              hint = 'Receive or move free stock of the component to the site, issue what is in containers or serial-numbered by hand, or take in fewer finished goods.';
    end if;
  end loop;

  return v_n;
end;
$$;

revoke all on function erp.backflush_works_order(uuid, numeric) from public, anon;

comment on function erp.backflush_works_order(uuid, numeric) is
  'Consumes, for a backflush works order, what is due for everything taken in so far (rounded to '
  'the unit, summed over the item''s lines) less what has been issued by any means, from the '
  'company''s own free stock at the site: active, unblocked, unexpired and uncommitted, in the '
  'item''s batch order, locked as it is taken (20260925200000, 20260925210000).';

-- An issue is credited to the first of the item's lines still short, then the
-- first: not to whichever the database finds.
do $issue$
declare
  v_sig constant text := 'erp.issue_to_works_order(uuid,uuid,numeric,uuid,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  select * into c from erp.works_order_component
   where tenant_id = v_tenant and works_order_id = p_works_order_id
     and item_id = p_component_item_id for update;$o$;
  v_new constant text := $n$  -- The first of the item's lines still short, then the first
  -- (20260925210000).
  select * into c from erp.works_order_component
   where tenant_id = v_tenant and works_order_id = p_works_order_id
     and item_id = p_component_item_id
   order by (issued_quantity >= required_quantity), seq
   limit 1
   for update;$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % line anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$issue$;

-- The suite gains three cases.
do $suite$
declare
  v_sig constant text := 'erp_test.backflush_default_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  v_fg2 uuid; v_c2 uuid; v_c3 uuid;$o$,
    $n$  v_fg5 uuid; v_c5 uuid; v_c6 uuid; v_c7 uuid; v_bom5 uuid; v_bad uuid; v_ok uuid; v_block uuid;
  v_alloc uuid; v_wo5 uuid; v_wo6 uuid; v_wo7 uuid; v_wo8 uuid;
  v_fg2 uuid; v_c2 uuid; v_c3 uuid;$n$,
    $o$    raise exception 'CLOVEERP_SUITE_UNDO';$o$,
    $n$    -- 8. An item on two lines, issued by hand: measured over both, not
    -- line by line (found on review: sixty consumed for fifty).
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'FG5', 'Twice the same', v_uom, 'active') returning id into v_fg5;
    insert into erp.bom (tenant_id, code, item_id, site_id, version, name,
                         output_quantity, yield_factor, status, effective_from)
    values (r.tenant_id, 'FG5-1', v_fg5, v_site, 1, 'Twice the same', 1, 1, 'active', current_date - 1)
    returning id into v_bom5;
    insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity, uom_id, scrap_factor, is_phantom)
    values (r.tenant_id, v_bom5, 10, v_comp, 2, v_uom, 0, false),
           (r.tenant_id, v_bom5, 20, v_comp, 3, v_uom, 0, false);
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_comp, 200, 100, 'component for twice');
    perform erp.transition_document(v_grn, 'post');
    v_wo5 := erp.raise_works_order(v_fg5, v_site, 10);
    perform erp.release_works_order(v_wo5);
    perform erp.issue_to_works_order(v_wo5, v_comp, 30);
    perform erp.receive_works_order_output(v_wo5, 10, null, v_recv);
    return query select 'an item on two lines of the bill, issued in part by hand, is consumed to what both lines ask and no more',
      (select sum(c.issued_quantity) from erp.works_order_component c where c.works_order_id = v_wo5) = 50,
      (select string_agg(format('line %s: %s of %s', c.seq, c.issued_quantity, c.required_quantity), '; ' order by c.seq)
         from erp.works_order_component c where c.works_order_id = v_wo5);

    -- 9. Not what is expired.
    insert into erp.item (tenant_id, code, name, stock_uom_id, is_batch_controlled, has_expiry, is_fefo, status)
    values (r.tenant_id, 'C5', 'Perishable', v_uom, true, true, true, 'active') returning id into v_c5;
    insert into erp.batch (tenant_id, item_id, batch_number, status, manufactured_on, expires_on)
    values (r.tenant_id, v_c5, 'OLD', 'released', current_date - 60, current_date - 1) returning id into v_bad;
    insert into erp.batch (tenant_id, item_id, batch_number, status, manufactured_on, expires_on)
    values (r.tenant_id, v_c5, 'NEW', 'released', current_date, current_date + 300) returning id into v_ok;
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_c5, 10, 100, 'old');
    perform erp.add_document_line(v_grn, v_c5, 10, 100, 'new');
    update erp.document_line set batch_id = case when line_no = 1 then v_bad else v_ok end where document_id = v_grn;
    perform erp.transition_document(v_grn, 'post');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'FG6', 'Made fresh', v_uom, 'active') returning id into v_fg5;
    insert into erp.bom (tenant_id, code, item_id, site_id, version, name,
                         output_quantity, yield_factor, status, effective_from)
    values (r.tenant_id, 'FG6-1', v_fg5, v_site, 1, 'Made fresh', 1, 1, 'active', current_date - 1)
    returning id into v_bom5;
    insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity, uom_id, scrap_factor, is_phantom)
    values (r.tenant_id, v_bom5, 10, v_c5, 1, v_uom, 0, false);
    v_wo6 := erp.raise_works_order(v_fg5, v_site, 5);
    perform erp.release_works_order(v_wo6);
    perform erp.receive_works_order_output(v_wo6, 5, null, v_recv);
    return query select 'an expired batch is not consumed, though it expires first',
      not exists (select 1 from erp.stock_movement m where m.works_order_id = v_wo6 and m.batch_id = v_bad)
      and (select sum(m.quantity) from erp.stock_movement m
            where m.works_order_id = v_wo6 and m.movement_type = 'production_issue' and m.batch_id = v_ok) = 5,
      (select string_agg(format('%s from %s', m.quantity, bt.batch_number), ', ')
         from erp.stock_movement m join erp.batch bt on bt.id = m.batch_id
        where m.works_order_id = v_wo6 and m.movement_type = 'production_issue');

    -- 10. Not a blocked location, and 11. not a pick's stock.
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'C6', 'Held in two places', v_uom, 'active') returning id into v_c6;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'BLOCK', 'Blocked', 'bulk', 'active') returning id into v_block;
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_c6, 10, 100, 'held in two places');
    perform erp.transition_document(v_grn, 'post');
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id,
                                    from_location_id, from_status, to_location_id, to_status, quantity, uom_id, reason_code)
    values (r.tenant_id, r.entity_id, v_site, 'internal_transfer', v_c6, v_recv, 'available', v_block, 'available', 5, v_uom, 'suite');
    update erp.location set is_blocked = true where id = v_block;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'FG7', 'Made from what is free', v_uom, 'active') returning id into v_fg5;
    insert into erp.bom (tenant_id, code, item_id, site_id, version, name,
                         output_quantity, yield_factor, status, effective_from)
    values (r.tenant_id, 'FG7-1', v_fg5, v_site, 1, 'Made from what is free', 1, 1, 'active', current_date - 1)
    returning id into v_bom5;
    insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity, uom_id, scrap_factor, is_phantom)
    values (r.tenant_id, v_bom5, 10, v_c6, 1, v_uom, 0, false);
    -- Of the five left in receiving, three are committed to a pick.
    insert into erp.allocation (tenant_id, entity_id, site_id, item_id, quantity, uom_id, status, demand_kind)
    values (r.tenant_id, r.entity_id, v_site, v_c6, 3, v_uom, 'committed', 'sales_order') returning id into v_alloc;
    insert into erp.allocation_line (tenant_id, allocation_id, location_id, stock_status, quantity, status)
    values (r.tenant_id, v_alloc, v_recv, 'available', 3, 'committed');
    v_wo7 := erp.raise_works_order(v_fg5, v_site, 4);
    perform erp.release_works_order(v_wo7);
    begin
      perform erp.receive_works_order_output(v_wo7, 4, null, v_recv);
      v_err := 'taken in';
    exception when others then v_err := left(sqlerrm, 220); end;
    perform erp.receive_works_order_output(v_wo7, 2, null, v_recv);
    return query select 'a blocked location and stock committed to a pick are not drawn on, and the shortfall says so',
      v_err like 'CLOVEERP_NO_COMPONENT_STOCK:%'
      and (select c.issued_quantity from erp.works_order_component c where c.works_order_id = v_wo7) = 2
      and (select b.quantity from erp.stock_balance b where b.item_id = v_c6 and b.location_id = v_block) = 5
      and (select b.quantity from erp.stock_balance b where b.item_id = v_c6 and b.location_id = v_recv) = 3,
      v_err;

    raise exception 'CLOVEERP_SUITE_UNDO';$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$suite$;

do $count$
declare
  v_sig constant text := 'erp_test.assert_backflush_default_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  if v_total <> 8 then
    raise exception 'CLOVEERP_BACKFLUSH_DEFAULT_SUITE_SHRANK: % case(s), expected 8', v_total$o$;
  v_new constant text := $n$  if v_total <> 11 then
    raise exception 'CLOVEERP_BACKFLUSH_DEFAULT_SUITE_SHRANK: % case(s), expected 11', v_total$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % count anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$count$;

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
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
