set lock_timeout = '30s';

-- =============================================================================
-- 20260924470000  A pick holds only what is left to go
-- -----------------------------------------------------------------------------
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- Pressing Pick (erp.pick_document) reserves every line of the order that
-- holds nothing, through erp.reserve_for_line, and that reserved the line's
-- whole ordered quantity. A line holds nothing once it has been delivered:
-- a posted delivery consumes what was held for it and releases the rest. So
-- on an order still part despatched, Pick held the whole of a line that had
-- already gone, or that the sales policy reads delivered under
-- short_close_pct (erp.sales_line_is_delivered, 20260924000000), and a part
-- delivered line that had never been reserved was held in full rather than
-- for what was still owed. The stock was held, and then picked, for goods
-- nothing would ship, and available-to-promise refused it to everybody else.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   erp.reserve_for_line   reserves what is left to go on the line: what was
--                          ordered less what posted deliveries delivered, read
--                          from erp.deliverable_lines. A line with nothing
--                          left, or one the sales policy reads delivered, is
--                          refused CLOVEERP_NOTHING_TO_RESERVE rather than
--                          held again.
--
--   erp.pick_document      reserves only the lines with something left to go
--                          that the sales policy does not read delivered, so
--                          one press on an order still part despatched holds
--                          the rest of it and nothing else. A line
--                          erp.deliverable_lines does not list (cancelled,
--                          without a product, or of no quantity) is not asked
--                          either; the reservation now refuses it.
--
-- A draft delivery still counts as left to go. It holds no stock of its own
-- (erp.available_to_promise does not read it), and when it posts it consumes
-- its quantity from what is held for the line, so holding only what no
-- delivery carries yet would leave the line short by the draft once it
-- posted. erp.deliverable_lines' open_quantity, which does take drafts off,
-- stays what a new delivery may take; the stock held is what has not left.
--
-- Nothing already held changes. A line the sales policy came to read
-- delivered after it was reserved keeps what it holds until its next
-- delivery releases it, as 20260924000000 records.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The reservation holds what is left to go
-- ─────────────────────────────────────────────────────────────────────────────

do $reserve$
declare
  v_sig constant text := 'erp.reserve_for_line(uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs text[][] := array[
    array[$o$  v_bo_rule text;
begin$o$,
          $n$  v_bo_rule text;
  v_need   numeric;
begin$n$],
    array[$o$  select * into a from erp.available_to_promise(l.item_id, d.site_id, current_date);$o$,
          $n$  -- What is left to go (20260924470000): what was ordered less what posted
  -- deliveries delivered. A draft delivery holds no stock of its own and,
  -- when it posts, consumes its quantity from what is held here, so its
  -- goods are still held. A line with nothing left, or one the sales policy
  -- reads delivered, has nothing to hold.
  select greatest(x.ordered_quantity - coalesce(x.delivered_quantity, 0), 0)
    into v_need
    from erp.deliverable_lines(l.document_id) x
   where x.line_id = l.id;

  if coalesce(v_need, 0) <= 0 then
    raise exception 'CLOVEERP_NOTHING_TO_RESERVE: line % of % has nothing left to deliver, so nothing is held for it',
      l.line_no, d.document_number
      using errcode = '23514',
            hint = 'Stock is held only for goods still to go. Reserve a line with something left on it.';
  end if;
  if erp.sales_line_is_delivered(l.id) then
    raise exception 'CLOVEERP_NOTHING_TO_RESERVE: line % of % has % left, which the sales policy reads delivered, so nothing is held for it',
      l.line_no, d.document_number, trim_scale(v_need)
      using errcode = '23514',
            hint = 'Stock is held only for goods still to go. Reserve a line with something left on it, or propose the sales policy with a smaller short close on the Sales screen.';
  end if;

  select * into a from erp.available_to_promise(l.item_id, d.site_id, current_date);$n$],
    array[$o$  v_res := least(l.quantity, greatest(a.available - v_short, 0));$o$,
          $n$  v_res := least(v_need, greatest(a.available - v_short, 0));$n$],
    array[$o$  v_unmet := l.quantity - v_res;$o$,
          $n$  v_unmet := v_need - v_res;$n$],
    array[$o$p_document_line_id, 'sales_order', l.quantity,$o$,
          $n$p_document_line_id, 'sales_order', v_need,$n$],
    array[$o$does not take a backorder', v_unmet, l.quantity$o$,
          $n$does not take a backorder', v_unmet, v_need$n$]];
  v_hits integer;
  i integer;
begin
  for i in 1 .. array_length(v_pairs, 1) loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[i][1], ''))) / length(v_pairs[i][1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[i][1], v_pairs[i][2]);
  end loop;
  -- Every use of the ordered quantity is now what is left to go.
  if position('l.quantity' in v_def) > 0 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % still reads l.quantity after the patch', v_sig;
  end if;
  execute v_def;
end
$reserve$;

comment on function erp.reserve_for_line(uuid, text) is
  'Reserves what is left to go on a sales order line: what was ordered less what '
  'posted deliveries delivered (20260924470000). Refuses a line that already holds '
  'stock, and one with nothing left or that the sales policy reads delivered '
  '(CLOVEERP_NOTHING_TO_RESERVE). A shortfall is recorded on the reservation and '
  'raised as a planning exception, or refused under sales.backorder_policy.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. Pick reserves only the lines with something left to go
-- ─────────────────────────────────────────────────────────────────────────────

do $pick$
declare
  v_sig constant text := 'erp.pick_document(uuid,uuid,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  for l in
    select dl.id from erp.document_line dl
     where dl.tenant_id = v_tenant and dl.document_id = p_document_id
     order by dl.line_no
  loop$o$;
  v_new constant text := $n$  for l in
    -- Only a line with something left to go, that the sales policy does not
    -- read delivered (20260924470000). A line that has gone holds nothing,
    -- because its delivery consumed and released what it held, and holding
    -- it again held stock for goods nothing would ship.
    select x.line_id as id
      from erp.deliverable_lines(p_document_id) x
     where x.ordered_quantity > coalesce(x.delivered_quantity, 0)
       and not erp.sales_line_is_delivered(x.line_id)
     order by x.line_no
  loop$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % line loop found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$pick$;

comment on function erp.pick_document(uuid, uuid, uuid) is
  'Reserves what is left to go on every line of the order that holds nothing, '
  'has something left and is not read delivered under the sales policy '
  '(20260924470000), then picks every reservation against real stock, so picking '
  'is one press rather than two.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. The refusal
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_NOTHING_TO_RESERVE',
  'Reserving stock for a sales order line with nothing left on it to deliver.',
  'Everything ordered on the line has been delivered, or so little is left that the sales policy counts the line as delivered. Stock is held only for goods still to go.',
  'Nothing needs holding for this line. Reserve a line with something left on it, or amend the order if more is owed.');

-- ─────────────────────────────────────────────────────────────────────────────
-- B. What proves it: erp_test.pick_holds_what_is_left_suite()
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.pick_holds_what_is_left_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_hex  text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1     uuid := gen_random_uuid();
  r      record;
  v_uom uuid; v_site uuid; v_sup uuid; v_cust uuid; v_wid uuid; v_gad uuid; v_grn uuid;
  v_so uuid; v_la uuid; v_lb uuid; v_dn uuid; v_pick jsonb; v_st text;
  v_gone uuid; v_closed uuid;
  v_held_a numeric; v_held_b numeric; v_n_a integer; v_n_b integer;
  v_held_before numeric; v_held_after numeric; v_unmet numeric;
  v_err1 text; v_err2 text;
begin
  begin
    select * into r from erp.provision_tenant(
      'zz-pick-' || v_hex, 'Pick suite',
      'admin@zz-pick-' || v_hex || '.test', 'Pick Admin');
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zz-pick-' || v_hex || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);

    select s.id into v_site from erp.site s
     where s.tenant_id = r.tenant_id and s.entity_id = r.entity_id order by s.code limit 1;
    select u.id into v_uom from erp.uom u
     where u.tenant_id = r.tenant_id and u.is_base and u.uom_class = 'quantity' and u.status = 'active'
     order by u.code limit 1;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZPKSUP', 'Pick Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZPKCUS', 'Pick Suite Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_cust, 'customer', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'ZPKWID', 'Pick Suite Widget', v_uom, 'active') returning id into v_wid;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'ZPKGAD', 'Pick Suite Gadget', v_uom, 'active') returning id into v_gad;
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_wid, 500, 100, 'the widgets');
    perform erp.add_document_line(v_grn, v_gad, 50, 100, 'the gadgets');
    perform erp.transition_document(v_grn, 'post', 'pick suite');

    -- 1. The case it was found by. Two lines; the first is delivered in full,
    --    which leaves the order part despatched; then Pick. The delivered
    --    line holds nothing, and the open one holds all of itself.
    v_so := erp.open_document('sales_order', v_cust, null, v_site);
    v_la := erp.add_document_line(v_so, v_wid, 10, 1000, 'Ten widgets');
    v_lb := erp.add_document_line(v_so, v_gad, 5, 1000, 'Five gadgets');
    perform erp.transition_document(v_so, 'submit', 'pick suite');
    perform erp_test.approve_document(v_so, 'pick suite');
    v_dn := (erp.create_delivery_from_order(v_so,
               jsonb_build_array(jsonb_build_object('line_id', v_la, 'quantity', 10))) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn, 'post', 'pick suite');
    v_st := erp.object_current_state('document', v_so);
    v_pick := erp.pick_document(v_so);
    select coalesce(sum(al.quantity - coalesce(al.unmet_quantity, 0)), 0), count(*)
      into v_held_a, v_n_a
      from erp.allocation al
     where al.tenant_id = r.tenant_id and al.document_line_id = v_la
       and al.status in ('reserved', 'committed', 'picked');
    select coalesce(sum(al.quantity - coalesce(al.unmet_quantity, 0)), 0), count(*)
      into v_held_b, v_n_b
      from erp.allocation al
     where al.tenant_id = r.tenant_id and al.document_line_id = v_lb
       and al.status in ('reserved', 'committed', 'picked');
    v_gone := v_la;
    return query select 'on an order part despatched, Pick holds nothing for the line delivered in full and all of the line still open',
      coalesce(v_st = 'partially_despatched'
               and v_held_a = 0 and v_n_a = 0
               and v_held_b = 5 and v_n_b = 1
               and (v_pick ->> 'reserved')::integer = 1, false),
      format('order %s; delivered line holds %s in %s reservation(s), open line %s in %s; pick %s',
             v_st, trim_scale(v_held_a), v_n_a, trim_scale(v_held_b), v_n_b, v_pick);

    -- 2. A line part delivered and never reserved: ten ordered, six
    --    delivered. Pick holds the four still owed, not ten.
    v_so := erp.open_document('sales_order', v_cust, null, v_site);
    v_la := erp.add_document_line(v_so, v_wid, 10, 1000, 'Ten widgets');
    perform erp.transition_document(v_so, 'submit', 'pick suite');
    perform erp_test.approve_document(v_so, 'pick suite');
    v_dn := (erp.create_delivery_from_order(v_so,
               jsonb_build_array(jsonb_build_object('line_id', v_la, 'quantity', 6))) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn, 'post', 'pick suite');
    perform erp.pick_document(v_so);
    select coalesce(sum(al.quantity), 0), coalesce(sum(coalesce(al.unmet_quantity, 0)), 0), count(*)
      into v_held_a, v_unmet, v_n_a
      from erp.allocation al
     where al.tenant_id = r.tenant_id and al.document_line_id = v_la
       and al.status in ('reserved', 'committed', 'picked');
    return query select 'a line part delivered is held for what is still owed, four of ten, and none of it is short',
      coalesce(v_held_a = 4 and v_unmet = 0 and v_n_a = 1, false),
      format('holds %s in %s reservation(s), %s short', trim_scale(v_held_a), v_n_a, trim_scale(v_unmet));

    -- 3. A draft delivery is still to go. Ten ordered and four on a draft:
    --    Pick holds ten, and posting the draft consumes its four from them,
    --    leaving six held for the six still owed. Holding only the six no
    --    delivery carries would leave two once the draft posted.
    v_so := erp.open_document('sales_order', v_cust, null, v_site);
    v_la := erp.add_document_line(v_so, v_wid, 10, 1000, 'Ten widgets');
    perform erp.transition_document(v_so, 'submit', 'pick suite');
    perform erp_test.approve_document(v_so, 'pick suite');
    v_dn := (erp.create_delivery_from_order(v_so,
               jsonb_build_array(jsonb_build_object('line_id', v_la, 'quantity', 4))) ->> 'document_id')::uuid;
    perform erp.pick_document(v_so);
    select coalesce(sum(al.quantity - coalesce(al.unmet_quantity, 0)), 0) into v_held_before
      from erp.allocation al
     where al.tenant_id = r.tenant_id and al.document_line_id = v_la
       and al.status in ('reserved', 'committed', 'picked');
    perform erp.transition_document(v_dn, 'post', 'pick suite');
    select coalesce(sum(al.quantity - coalesce(al.unmet_quantity, 0)), 0) into v_held_after
      from erp.allocation al
     where al.tenant_id = r.tenant_id and al.document_line_id = v_la
       and al.status in ('reserved', 'committed', 'picked');
    return query select 'goods on a draft delivery are still held, and posting it leaves held exactly what is still owed',
      coalesce(v_held_before = 10 and v_held_after = 6, false),
      format('with a draft of four: holds %s; after it posts: holds %s',
             trim_scale(v_held_before), trim_scale(v_held_after));

    -- 4. The sales policy. At a short close of two per cent, ninety-nine of a
    --    hundred reads delivered while another line keeps the order part
    --    despatched; Pick holds nothing for the hundred and all of the other.
    perform erp.set_config_value('sales.policy', jsonb_build_object('short_close_pct', 2),
      null, null, r.entity_id, null, 'pick suite');
    v_so := erp.open_document('sales_order', v_cust, null, v_site);
    v_la := erp.add_document_line(v_so, v_wid, 100, 1000, 'A hundred widgets');
    v_lb := erp.add_document_line(v_so, v_gad, 5, 1000, 'Five gadgets');
    perform erp.transition_document(v_so, 'submit', 'pick suite');
    perform erp_test.approve_document(v_so, 'pick suite');
    v_dn := (erp.create_delivery_from_order(v_so,
               jsonb_build_array(jsonb_build_object('line_id', v_la, 'quantity', 99))) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn, 'post', 'pick suite');
    v_st := erp.object_current_state('document', v_so);
    v_pick := erp.pick_document(v_so);
    select coalesce(sum(al.quantity - coalesce(al.unmet_quantity, 0)), 0), count(*)
      into v_held_a, v_n_a
      from erp.allocation al
     where al.tenant_id = r.tenant_id and al.document_line_id = v_la
       and al.status in ('reserved', 'committed', 'picked');
    select coalesce(sum(al.quantity - coalesce(al.unmet_quantity, 0)), 0), count(*)
      into v_held_b, v_n_b
      from erp.allocation al
     where al.tenant_id = r.tenant_id and al.document_line_id = v_lb
       and al.status in ('reserved', 'committed', 'picked');
    v_closed := v_la;
    return query select 'a line the sales policy reads delivered is not held by Pick, and the line still open is',
      coalesce(v_st = 'partially_despatched'
               and erp.sales_line_is_delivered(v_la)
               and v_held_a = 0 and v_n_a = 0
               and v_held_b = 5 and v_n_b = 1
               and (v_pick ->> 'reserved')::integer = 1, false),
      format('order %s; ninety-nine of a hundred holds %s in %s reservation(s), gadgets %s in %s; pick %s',
             v_st, trim_scale(v_held_a), v_n_a, trim_scale(v_held_b), v_n_b, v_pick);

    -- 5. Reserving such a line directly is refused by name, and says which.
    begin
      perform erp.reserve_for_line(v_gone);
      v_err1 := 'reserved';
    exception when others then v_err1 := left(sqlerrm, 300); end;
    begin
      perform erp.reserve_for_line(v_closed);
      v_err2 := 'reserved';
    exception when others then v_err2 := left(sqlerrm, 300); end;
    return query select 'reserving a line delivered in full, or one the sales policy reads delivered, is refused by name',
      coalesce(v_err1 like 'CLOVEERP_NOTHING_TO_RESERVE:%has nothing left to deliver%'
               and v_err2 like 'CLOVEERP_NOTHING_TO_RESERVE:%has 1 left, which the sales policy reads delivered%', false),
      format('delivered in full: %s; read delivered: %s', v_err1, v_err2);

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-pick-' || v_hex);
  detail := 'the organisation, its orders, deliveries and reservations rolled back';
  return next;
end;
$function$;

create or replace function erp_test.assert_pick_holds_what_is_left_suite()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.pick_holds_what_is_left_suite() s;
  -- Failures first: a case that raised ends the suite early, and its message
  -- is what to read, not the count it left.
  if v_failed > 0 then
    raise exception 'CLOVEERP_PICK_HOLDS_WHAT_IS_LEFT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'Pick held stock for a line that has gone, or held a line short of what is still owed. Read the case that failed.';
  end if;
  if v_total <> 6 then
    raise exception 'CLOVEERP_PICK_HOLDS_WHAT_IS_LEFT_SUITE_SHRANK: % case(s), expected 6', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
end;
$$;

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
