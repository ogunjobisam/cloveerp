set lock_timeout = '30s';

-- =============================================================================
-- 20260925600000  A works order is made in four presses
-- -----------------------------------------------------------------------------
-- PR8, M8: node M8 of docs/spec/simplification-review.md, the manufacturing
-- step budget of four, reached as the plan's rationale for it says: release
-- folded into the press that makes the order, and materials backflushed
-- (20260925200000) rather than taken out by hand.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
--   * The making strip drew six presses: make the order, release it, take
--     out the materials, record the hours, take in the finished goods, close.
--     Confirming a planned order already released it (20260925100000), but an
--     order made on the strip waited for a second press that decides nothing
--     not known when it was made; and backflush, the installed default, takes
--     the materials out as the goods come in, so a press for them is the
--     exception, not the cycle.
--   * erp_meta.flow_budget recorded the six as today's cost, and nothing
--     walked the cycle to count it.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   * erp.release_when_ready(): what confirming a planned order did to release
--     it, as one function both presses call. It releases the order, or leaves
--     it a draft and its history says why: not due to start yet, the person
--     does not release orders, short of material past the production policy,
--     or the organisation's own lifecycle refuses. Anything else refuses the
--     whole, as it always did.
--   * public.erp_raise_works_order releases the order it makes, through it.
--     An order made by hand is due when somebody makes it: nothing records a
--     lead time to start it later by, and a confirmed planned order, which
--     has a date to start, still waits for it.
--   * The strip is four: the works order, the hours, the finished goods, the
--     close. Releasing an order that waited and taking out materials by hand
--     stay actions on the module, where an exception is dealt with.
--   * The make cycle's budget is four, with its reason, and
--     erp_test.step_budget_suite walks it: one person who is not an
--     administrator, four public doors, and the order read back closed, its
--     material consumed and its goods in stock.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. Released as it is made, or waiting with its reason
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.release_when_ready(p_works_order_id uuid,
                                                  p_release_on date default null,
                                                  p_detail jsonb default '{}'::jsonb)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  wo       erp.works_order%rowtype;
  v_held   text;
  v_why    text;
begin
  select * into wo from erp.works_order
   where tenant_id = v_tenant and id = p_works_order_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_WORKS_ORDER: %', p_works_order_id using errcode = '23503';
  end if;

  -- Release decides nothing that was not known when the order was made
  -- (20260925100000). It waits unreleased, and its history says which, where
  --   * it is not due to start yet: releasing commits its material, and an
  --     order made weeks ahead would hold stock an order due sooner needs.
  --     Only a confirmed planned order carries a date to start; an order
  --     made by hand is due when somebody makes it;
  --   * the person does not release orders: asked before, not caught after,
  --     so the refusal is not rolled out of the access log while the order
  --     commits;
  --   * it is short of material past the production policy, or the
  --     organisation's own lifecycle refuses the release.
  -- Anything else refuses the whole.
  if p_release_on is not null and p_release_on > erp.local_today(wo.site_id) then
    v_why := 'not_due';
    v_held := format('%s is not due to start until %s', wo.order_number, p_release_on);
  elsif not erp.has_permission('production.release', wo.entity_id, wo.site_id)
     -- Nor what the organisation's own lifecycle asks of the release, which
     -- may be more (found on review: a lifecycle naming another permission
     -- refused the whole raise, and the refusal left the access log with it).
     or exists (select 1 from erp.available_transitions('works_order', p_works_order_id, null) a
                 where a.transition_code = 'release' and not a.permitted) then
    v_why := 'not_permitted';
    v_held := 'releasing works orders is not part of this person''s role';
  else
    begin
      perform erp.release_works_order(p_works_order_id);
    exception
      when sqlstate '23514' then
        if sqlerrm not like 'CLOVEERP_MATERIAL_SHORTAGE:%'
           and sqlerrm not like 'CLOVEERP_TRANSITION_GUARD_FAILED:%'
           and sqlerrm not like 'CLOVEERP_TRANSITION_NOT_PERMITTED:%' then
          raise;
        end if;
        v_why := case when sqlerrm like 'CLOVEERP_MATERIAL_SHORTAGE:%' then 'short' else 'refused' end;
        v_held := sqlerrm;
    end;
  end if;

  if v_held is not null then
    insert into erp.production_event (
      tenant_id, works_order_id, event_kind, detail, actor_id)
    values (v_tenant, p_works_order_id, 'held',
            coalesce(p_detail, '{}'::jsonb) || jsonb_build_object('why', v_why, 'reason', v_held),
            erp.current_principal_id());
  end if;

  return p_works_order_id;
end;
$$;

revoke all on function erp.release_when_ready(uuid, date, jsonb) from public, anon;

comment on function erp.release_when_ready(uuid, date, jsonb) is
  'Releases a works order as it is made, or leaves it a draft with a held event saying why: not '
  'due, not permitted, short, or refused by the lifecycle (20260925600000).';

-- Confirming a planned order releases through it, so the two presses cannot
-- come to disagree.
do $firm$
declare
  v_sig constant text := 'erp.firm_planned_order(uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    if po.release_on is not null and po.release_on > erp.local_today(po.site_id) then
      v_why := 'not_due';
      v_held := format('%s is not due to start until %s', po.id, po.release_on);
    elsif not erp.has_permission('production.release', po.entity_id, po.site_id) then
      v_why := 'not_permitted';
      v_held := 'releasing works orders is not part of the confirming person''s role';
    else
      begin
        perform erp.release_works_order(v_wo);
      exception
        when sqlstate '23514' then
          if sqlerrm not like 'CLOVEERP_MATERIAL_SHORTAGE:%'
             and sqlerrm not like 'CLOVEERP_TRANSITION_GUARD_FAILED:%'
             and sqlerrm not like 'CLOVEERP_TRANSITION_NOT_PERMITTED:%' then
            raise;
          end if;
          v_why := case when sqlerrm like 'CLOVEERP_MATERIAL_SHORTAGE:%' then 'short' else 'refused' end;
          v_held := sqlerrm;
      end;
    end if;

    if v_held is not null then
      insert into erp.production_event (
        tenant_id, works_order_id, event_kind, detail, actor_id)
      values (v_tenant, v_wo, 'held',
              jsonb_build_object('planned_order_id', po.id, 'why', v_why, 'reason', v_held),
              erp.current_principal_id());
    end if;
$o$;
  v_new constant text := $n$    perform erp.release_when_ready(v_wo, po.release_on,
                                   jsonb_build_object('planned_order_id', po.id));
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$firm$;

-- The press that makes an order releases it.
do $raise$
declare
  v_sig constant text := 'public.erp_raise_works_order(uuid,uuid,numeric,erp.works_order_kind,date)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$ select erp.raise_works_order(p_item_id, p_site_id, p_quantity, p_kind, p_planned_end) $o$;
  v_new constant text := $n$
  -- Released as it is made, or waiting with its reason (20260925600000).
  select erp.release_when_ready(erp.raise_works_order(p_item_id, p_site_id, p_quantity, p_kind, p_planned_end))
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$raise$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The make cycle's budget is four
-- ─────────────────────────────────────────────────────────────────────────────

update erp_meta.flow_budget
   set budget = 4, decision_steps = 4, stages = 4, stages_without_a_list = 0,
       rationale = 'The plan''s target, reached (20260925600000): the order is released as it is made, '
                || 'and backflush takes the materials out as the goods come in. Releasing an order that '
                || 'waited, and taking out materials by hand, are actions for the exception. Walked by '
                || 'erp_test.step_budget_suite: one person, four presses, the order closed.'
 where flow_code = 'make';

do $check$
begin
  if not exists (select 1 from erp_meta.flow_budget where flow_code = 'make' and budget = 4) then
    raise exception 'CLOVEERP_FLOW_BUDGET_MISSING: the make cycle declares no budget to lower';
  end if;
end
$check$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. What the strip and the actions now say
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A works order made in four presses (20260925600000).'
  from (values
    ('Create the order, which goes to the floor as it is made, record the hours, take in the finished goods and close it. The materials go out as the goods come in.'),
    ('What is to be made, how much, and by when. It is released as it is made, unless it has to wait.'),
    ('For an order that waited: a planned order confirmed before it is due, one short of material, or one made by somebody who does not release orders.'),
    ('By hand, for an order that does not backflush or a component taken out ahead of the goods. Backflush takes the rest as the goods come in.')
  ) v(text)
on conflict (key, locale) do update set value = excluded.value;

delete from erp_ref.resource
 where key in (erp_ref.ui_key('Create the order, release it to the floor, take out the materials, record the hours, take in the finished goods and close it.'),
               erp_ref.ui_key('What is to be made, how much, and by when.'),
               erp_ref.ui_key('Releasing an order is what makes it work the floor can start.'),
               erp_ref.ui_key('Orders appear here once one has been created at the works order step.'),
               erp_ref.ui_key('Stock leaves the store and joins the order''s cost.'));

-- What the help and the register say of making an order.
do $words$
declare
  v_n integer;
begin
  update erp_ref.help_topic
     set steps = jsonb_build_array(
           'Raise a works order for a product with a bill of materials. It is released as it is raised, unless it has to wait.',
           'Record the hours, then receive the output; the components go out with it.',
           'Close the order. The batch record and cost follow.'),
         next_action = 'Raise the works order; release by hand only one that waited.'
   where screen_path = '/production'
     and next_action = 'Release the works order when material is available.';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the production help changed % row(s), expected 1', v_n;
  end if;

  update erp_meta.public_write_allowance
     set rationale = 'Raises a works order under production.order, which is where every production movement '
                  || 'afterwards hangs from, and releases it through erp.release_when_ready() where it can '
                  || '(20260925600000).'
   where function_name = 'erp_raise_works_order';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the raise door''s allowance changed % row(s), expected 1', v_n;
  end if;
end
$words$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The proof: the make cycle, walked
-- ─────────────────────────────────────────────────────────────────────────────

-- Counted by pressing, not by reading the screens: one person who holds the
-- production role and is not an administrator, four public doors, and the
-- order read back where the cycle leaves it.
create or replace function erp_test.make_walk()
 returns jsonb
 language plpgsql
 set search_path to ''
as $function$
declare
  c_undo   constant text := 'CLOVEERP_MAKE_WALK_UNDO';
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_code   text;
  a1       uuid := gen_random_uuid();   -- the first administrator, who sets up
  a2       uuid := gen_random_uuid();   -- the second, who approves the changes
  s_make   uuid := gen_random_uuid();
  p_make   uuid;
  r        record;
  res      jsonb;
  v_tok_a2 text;
  v_tok_m  text;
  cs_fin   uuid;
  cs_inv   uuid;
  cs_proc  uuid;
  cs_prod  uuid;
  v_uom    uuid;
  v_site   uuid;
  v_recv   uuid;
  v_sup    uuid;
  v_fg     uuid;
  v_comp   uuid;
  v_bom    uuid;
  v_rout   uuid;
  v_grn    uuid;
  v_wo     uuid;
  v_steps  jsonb := '[]'::jsonb;
  v_subs   uuid[] := '{}';
  v_block  text;
  v_admins integer;
  v_out    jsonb;
begin
  begin
    v_code := 'zzmake-' || v_hex;
    select * into r from erp.provision_tenant(
      v_code, 'Make walk', 'admin@' || v_code || '.test', 'Walk Admin');

    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp_test.administrator_approval_off(r.tenant_id);

    res := public.erp_invite_principal('second@' || v_code || '.test', 'Second Admin');
    v_tok_a2 := res ->> 'token';
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'administrator', null, null, 'co-administrator');
    res := public.erp_invite_principal('maker@' || v_code || '.test', 'Mo Maker');
    p_make := (res ->> 'app_user_id')::uuid; v_tok_m := res ->> 'token';
    perform erp.grant_role(p_make, 'production', null, null, 'makes things');

    -- Installed as the Configuration screen installs it: production with its
    -- default, backflush. Live, so the other administrator approves and
    -- promotes each change.
    cs_fin := erp.configure_finance();
    cs_inv := erp.configure_inventory('average');
    select (d ->> 'lifecycle_change_set_id')::uuid into cs_proc
      from public.erp_configure_procurement(1000000, null) d;
    cs_prod := erp.configure_production();

    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok_a2);
    perform erp.approve_change_set(cs_fin);
    perform erp.promote_change_set(cs_fin);
    perform erp.approve_change_set(cs_inv);
    perform erp.promote_change_set(cs_inv);
    perform erp.approve_change_set(cs_proc);
    perform erp.promote_change_set(cs_proc);
    perform erp.approve_change_set(cs_prod);
    perform erp.promote_change_set(cs_prod);

    perform set_config('request.jwt.claims', json_build_object('sub', s_make)::text, true);
    perform erp.claim_invitation(v_tok_m);

    -- Master data, a bill and a routing, and the component in stock, as a
    -- fixture.
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'production', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'RECV', 'Receiving', 'receiving', 'active') returning id into v_recv;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'FG', 'Finished good', v_uom, 'active') returning id into v_fg;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'C1', 'Component', v_uom, 'active') returning id into v_comp;
    insert into erp.bom (tenant_id, code, item_id, site_id, version, name, output_quantity, yield_factor, status, effective_from)
    values (r.tenant_id, 'FG-1', v_fg, v_site, 1, 'Finished good', 1, 1, 'active', current_date - 1) returning id into v_bom;
    insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity, uom_id, scrap_factor, is_phantom)
    values (r.tenant_id, v_bom, 10, v_comp, 2, v_uom, 0, false);
    insert into erp.routing (tenant_id, code, item_id, site_id, version, name, status, effective_from)
    values (r.tenant_id, 'FG-R1', v_fg, v_site, 1, 'Make', 'active', current_date - 1) returning id into v_rout;
    insert into erp.routing_operation (tenant_id, routing_id, seq, code, name, work_centre_code,
                                       setup_minutes, run_minutes_per_unit, cost_rate_minor_per_hour)
    values (r.tenant_id, v_rout, 10, 'MAKE', 'Make', 'WC1', 0, 6, 6000);
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_comp, 100, 500, 'the component');
    perform erp.transition_document(v_grn, 'post', 'make walk');

    select count(*) into v_admins
      from erp.organisation_administrators() a
     where a.app_user_id = p_make;

    -- ─────────────────────────────────────────────────────────────────────
    -- The four presses.
    -- ─────────────────────────────────────────────────────────────────────
    -- 1. The maker makes the order for ten, and it is released as it is made.
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', s_make)::text, true);
      v_wo := public.erp_raise_works_order(v_fg, v_site, 10, 'assembly', current_date + 7);
      v_steps := v_steps || jsonb_build_object('step', 1, 'door', 'erp_raise_works_order',
                   'person', 'maker', 'result', v_wo);
      v_subs := v_subs || s_make;
    exception when others then
      v_block := format('1 maker erp_raise_works_order: %s', left(sqlerrm, 300));
    end;

    -- 2. The maker records the hour worked.
    if v_block is null then
      begin
        perform set_config('request.jwt.claims', json_build_object('sub', s_make)::text, true);
        perform public.erp_book_operation_time(v_wo, 10, 60, 10, 0);
        v_steps := v_steps || jsonb_build_object('step', 2, 'door', 'erp_book_operation_time',
                     'person', 'maker');
        v_subs := v_subs || s_make;
      exception when others then
        v_block := format('2 maker erp_book_operation_time: %s', left(sqlerrm, 300));
      end;
    end if;

    -- 3. The maker takes in the ten, and the components go out with them.
    if v_block is null then
      begin
        perform set_config('request.jwt.claims', json_build_object('sub', s_make)::text, true);
        res := to_jsonb(public.erp_receive_works_order_output(v_wo, 10, null, v_recv));
        v_steps := v_steps || jsonb_build_object('step', 3, 'door', 'erp_receive_works_order_output',
                     'person', 'maker', 'result', res);
        v_subs := v_subs || s_make;
      exception when others then
        v_block := format('3 maker erp_receive_works_order_output: %s', left(sqlerrm, 300));
      end;
    end if;

    -- 4. The maker closes the order.
    if v_block is null then
      begin
        perform set_config('request.jwt.claims', json_build_object('sub', s_make)::text, true);
        res := to_jsonb(public.erp_close_works_order(v_wo));
        v_steps := v_steps || jsonb_build_object('step', 4, 'door', 'erp_close_works_order',
                     'person', 'maker', 'result', res);
        v_subs := v_subs || s_make;
      exception when others then
        v_block := format('4 maker erp_close_works_order: %s', left(sqlerrm, 300));
      end;
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_out := jsonb_build_object(
      'presses', jsonb_array_length(v_steps),
      'people', (select count(distinct u) from unnest(v_subs) u),
      'administrators_pressing', v_admins,
      'order_state', (select wo.status::text from erp.works_order wo where wo.id = v_wo),
      'held', exists (select 1 from erp.production_event e
                       where e.works_order_id = v_wo and e.event_kind = 'held'),
      'events', (select coalesce(jsonb_agg(e.event_kind order by e.occurred_at, e.id), '[]'::jsonb)
                   from erp.production_event e where e.works_order_id = v_wo),
      'component_left', (select coalesce(sum(sb.quantity), 0) from erp.stock_balance sb
                          where sb.tenant_id = r.tenant_id and sb.item_id = v_comp),
      'made_in_stock', (select coalesce(sum(sb.quantity), 0) from erp.stock_balance sb
                         where sb.tenant_id = r.tenant_id and sb.item_id = v_fg
                           and sb.stock_status = 'available'),
      'blocked', v_block,
      'steps', v_steps);

    raise exception using message = c_undo;
  exception when others then
    if sqlerrm <> c_undo then
      v_out := jsonb_build_object('presses', 0, 'people', 0, 'blocked',
                 'setting up: ' || left(sqlerrm, 300), 'steps', v_steps);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return v_out;
end;
$function$;

revoke all on function erp_test.make_walk() from public, anon;

comment on function erp_test.make_walk() is
  'The make cycle walked by one person who is not an administrator, in four public doors, '
  'and read back: released as it was made, closed, its material consumed (20260925600000).';

-- The walk joins the step budget suite as its tenth case.
do $suite$
declare
  v_sig constant text := 'erp_test.step_budget_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  c_expected constant integer := 9;$o$,
    $n$  c_expected constant integer := 10;$n$,
    $o$  v_o2c     jsonb;$o$,
    $n$  v_o2c     jsonb;
  v_make    jsonb;$n$,
    $o$  if v_cases <> c_expected then$o$,
    $n$  -- ── 10. Making, walked ─────────────────────────────────────────────────
  --
  -- The plan's target for the cycle is four (20260925600000). One person
  -- who is not an administrator, four presses: the order made and released
  -- in one, the hours, the goods in with the materials out, the close.
  v_make := erp_test.make_walk();

  v_cases := v_cases + 1;
  case_name := 'the make cycle is walked by one person in four presses: the order released as it is made, the hours, the goods in with their materials out, and the order closed';
  passed := coalesce(v_make ->> 'blocked' is null
            and (v_make ->> 'presses')::integer = 4
            and (v_make ->> 'people')::integer = 1
            and (v_make ->> 'administrators_pressing')::integer = 0
            and v_make ->> 'order_state' = 'closed'
            and not (v_make ->> 'held')::boolean
            and (v_make ->> 'component_left')::numeric = 80
            and (v_make ->> 'made_in_stock')::numeric = 10
            and v_make -> 'events' = jsonb_build_array(
                  'released', 'time_booked', 'issued', 'output_received', 'closed'), false);
  detail := coalesce('blocked at ' || (v_make ->> 'blocked') || '; ', '')
            || format('%s press(es) by %s people (%s of them administrators); the order reads %s; held %s; events %s; %s of the component left, %s made in stock',
                      coalesce(v_make ->> 'presses', '0'), coalesce(v_make ->> 'people', '0'),
                      coalesce(v_make ->> 'administrators_pressing', 'an unknown number'),
                      coalesce(v_make ->> 'order_state', 'nothing'),
                      coalesce(v_make ->> 'held', 'unknown'),
                      coalesce(v_make ->> 'events', '[]'),
                      coalesce(v_make ->> 'component_left', 'none'),
                      coalesce(v_make ->> 'made_in_stock', 'none'));
  return next;

  if v_cases <> c_expected then$n$];
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

do $assert$
declare
  v_sig constant text := 'erp_test.assert_step_budget_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  c_expected constant integer := 9;$o$;
  v_new constant text := $n$  c_expected constant integer := 10;$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$assert$;

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
