set lock_timeout = '30s';

-- =============================================================================
-- 20260925100000  A planned order is firmed onto the floor
-- -----------------------------------------------------------------------------
-- PR8, M4 of docs/spec/simplification-review.md: firm and release in one
-- action.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
--   * Confirming a planned order for a made item raised a works order in
--     draft, and somebody then had to find it on the Manufacturing screen and
--     press Release. Everything release decides is known when the plan is
--     confirmed: the bill, the routing, the material on hand and the policy
--     that says how short is too short. The second press added nothing but a
--     place for the order to wait.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   * erp.firm_planned_order() releases the works order it raises, in the same
--     transaction, through erp.release_works_order(): the same checks, the
--     same commitment, the same frozen standard and the same decision about
--     whether it posts.
--   * A shortage is the exception, not a failure. Where the production policy
--     refuses the release for material, the planned order is still confirmed,
--     the works order waits unreleased, and the release that refused says why
--     in the order's history. So does an order not yet due to start, which
--     would otherwise commit its material weeks early; a person whose role
--     confirms plans but does not release orders, since planning is not handed
--     production's permission by the back door; and a release the
--     organisation's own lifecycle refuses.
--   * Any other refusal refuses the confirmation, as it always did.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. An order confirmed and not released says why
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp.production_event drop constraint if exists production_event_event_kind_check;
alter table erp.production_event add constraint production_event_event_kind_check
  check (event_kind = any (array['released', 'started', 'issued', 'completed', 'scrapped',
                                 'time_booked', 'deviation', 'output_received', 'closed',
                                 'cancelled', 'returned', 'output_reversed', 'held']));

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. Firming releases
-- ─────────────────────────────────────────────────────────────────────────────

do $firm$
declare
  v_sig constant text := 'erp.firm_planned_order(uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  v_doc    uuid;
  v_wo     uuid;
begin$o$,
    $n$  v_doc    uuid;
  v_wo     uuid;
  v_held   text;
  v_why    text;
begin$n$,
    $o$    update erp.planned_order
       set status = 'converted', converted_works_order_id = v_wo,
           converted_at = now(), updated_at = now()
     where id = p_planned_order_id;

    return v_wo;$o$,
    $n$    update erp.planned_order
       set status = 'converted', converted_works_order_id = v_wo,
           converted_at = now(), updated_at = now()
     where id = p_planned_order_id;

    -- Released as it is confirmed (20260925100000): release decides nothing
    -- that was not known now. It waits unreleased, and its history says
    -- which, where
    --   * it is not due to start yet: releasing commits its material, and a
    --     plan confirmed weeks ahead would hold stock an order due sooner
    --     needs (found on review);
    --   * the person confirming does not release orders: asked before, not
    --     caught after, so the refusal is not rolled out of the access log
    --     while the confirmation commits (found on review);
    --   * it is short of material past the production policy, or the
    --     organisation's own lifecycle refuses the release.
    -- Anything else refuses the whole, as it always did.
    if po.release_on is not null and po.release_on > erp.local_today(po.site_id) then
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

    return v_wo;$n$];
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
$firm$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The words the Planning screen says for it
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A planned order confirmed and released in one action (20260925100000).'
  from (values
    ('A bought item becomes a purchase order of the type you name; a made item becomes a works order, released to the floor once it is due to start, unless its material is short or releasing is not yours to do.'),
    ('A confirmed order becomes a purchase order, or a works order released to the floor when it is due, and leaves planning.')
  ) v(text)
on conflict (key, locale) do update set value = excluded.value;

-- The words they replace, which nothing says any more.
delete from erp_ref.resource
 where key in (erp_ref.ui_key('A bought item becomes a purchase order of the type you name; a made item becomes a works order.'),
               erp_ref.ui_key('A confirmed order becomes a purchase order or a works order and leaves planning.'));

-- ─────────────────────────────────────────────────────────────────────────────
-- B2. The proof: erp_test.planned_order_firming_suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.planned_order_firming_suite()
 returns table(case_name text, passed boolean, detail text)
 language plpgsql
 set search_path to ''
as $function$
declare
  v_hex   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1      uuid := gen_random_uuid();
  a2      uuid := gen_random_uuid();
  a3      uuid := gen_random_uuid();
  r       record;
  res     jsonb;
  v_tok   text; v_tok3 text;
  v_second uuid; v_planner uuid;
  csf uuid; csp uuid; csi uuid; csr uuid;
  v_uom uuid; v_site uuid; v_sup uuid;
  v_fg uuid; v_comp uuid; v_bom uuid; v_rout uuid; v_grn uuid;
  v_po1 uuid; v_po2 uuid; v_po3 uuid; v_po4 uuid; v_demand uuid;
  v_wo1 uuid; v_wo2 uuid; v_wo3 uuid; v_wo4 uuid;
  v_err text;
begin
  begin
    select * into r from erp.provision_tenant(
      'zz-pof-' || v_hex, 'Planned order firming suite',
      'a@zz-pof-' || v_hex || '.test', 'Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zz-pof-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
    res := public.erp_invite_principal('planner@zz-pof-' || v_hex || '.test', 'Planner');
    v_planner := (res ->> 'app_user_id')::uuid; v_tok3 := res ->> 'token';
    csf := erp.configure_finance();
    csp := erp.configure_procurement(100000000);
    csi := erp.configure_inventory('average');
    csr := erp.configure_production('manual');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
    perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
    perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
    perform erp.approve_change_set(csr); perform erp.promote_change_set(csr);
    -- Somebody who confirms plans and raises the orders they become, and
    -- does not release them. A role is configuration, so the organisation is
    -- not live while the suite writes one.
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    with ro as (
      insert into erp.role (tenant_id, code, name, status)
      values (r.tenant_id, 'order_planner', 'Order planner', 'active') returning id)
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    select r.tenant_id, ro.id, p.code
      from ro, (values ('planning.read'), ('planning.firm'), ('production.read'), ('production.order')) p(code);
    perform erp.grant_role(v_planner, 'order_planner', null, null, 'plans, and does not release');
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(v_tok3);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'production', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'RECV', 'Receiving', 'receiving', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'FG', 'Finished good', v_uom, 'active') returning id into v_fg;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'C1', 'Component', v_uom, 'active') returning id into v_comp;
    insert into erp.bom (tenant_id, code, item_id, site_id, version, name,
                         output_quantity, yield_factor, status, effective_from)
    values (r.tenant_id, 'FG-1', v_fg, v_site, 1, 'Finished good', 1, 1, 'active', current_date - 1)
    returning id into v_bom;
    insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity, uom_id, scrap_factor, is_phantom)
    values (r.tenant_id, v_bom, 10, v_comp, 1, v_uom, 0, false);
    insert into erp.routing (tenant_id, code, item_id, site_id, version, name, status, effective_from)
    values (r.tenant_id, 'FG-R1', v_fg, v_site, 1, 'Assemble', 'active', current_date - 1)
    returning id into v_rout;
    insert into erp.routing_operation (
      tenant_id, routing_id, seq, code, name, work_centre_code,
      setup_minutes, run_minutes_per_unit, cost_rate_minor_per_hour)
    values (r.tenant_id, v_rout, 10, 'ASM', 'Assembly', 'WC1', 10, 1, 6000);

    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_comp, 100, 100, 'component');
    perform erp.transition_document(v_grn, 'post');

    -- Three planned orders, as a run writes them, each pegged to the demand
    -- behind it: a fourth, for the finished good the plan was asked for.
    insert into erp.planned_order (tenant_id, entity_id, site_id, item_id, order_kind, quantity, uom_id,
                                   required_by, release_on, status)
    values (r.tenant_id, r.entity_id, v_site, v_fg, 'production', 1, v_uom, current_date + 20, current_date + 15, 'suggested')
    returning id into v_demand;
    insert into erp.planned_order (tenant_id, entity_id, site_id, item_id, order_kind, quantity, uom_id,
                                   required_by, release_on, status)
    values (r.tenant_id, r.entity_id, v_site, v_fg, 'production', 10, v_uom, current_date + 10, current_date, 'suggested')
    returning id into v_po1;
    insert into erp.planned_order (tenant_id, entity_id, site_id, item_id, order_kind, quantity, uom_id,
                                   required_by, release_on, status)
    values (r.tenant_id, r.entity_id, v_site, v_fg, 'production', 500, v_uom, current_date + 10, current_date, 'suggested')
    returning id into v_po2;
    insert into erp.planned_order (tenant_id, entity_id, site_id, item_id, order_kind, quantity, uom_id,
                                   required_by, release_on, status)
    values (r.tenant_id, r.entity_id, v_site, v_fg, 'production', 5, v_uom, current_date + 10, current_date, 'suggested')
    returning id into v_po3;
    insert into erp.planned_order (tenant_id, entity_id, site_id, item_id, order_kind, quantity, uom_id,
                                   required_by, release_on, status)
    values (r.tenant_id, r.entity_id, v_site, v_fg, 'production', 60, v_uom, current_date + 40, current_date + 30, 'suggested')
    returning id into v_po4;
    insert into erp.planned_order_peg (tenant_id, planned_order_id, demand_kind, demand_planned_order_id, quantity, required_by)
    select r.tenant_id, x, 'planned_order', v_demand, 1, current_date + 10
      from unnest(array[v_po1, v_po2, v_po3, v_po4]) x;

    -- 1. Confirmed with the material there: on the floor in one press.
    v_wo1 := public.erp_firm_planned_order(v_po1, null);
    return query select 'a planned order confirmed with its material on hand is a works order released to the floor',
      (select wo.status::text = 'released' and wo.planned_order_id = v_po1 and wo.planned_start = current_date
              and wo.standard_cost_minor = 1000 + 2000 and wo.posts_to_ledger
         from erp.works_order wo where wo.id = v_wo1)
      and exists (select 1 from erp.allocation a
                   where a.document_id = v_wo1 and a.demand_kind = 'works_order' and a.status = 'committed'
                     and a.quantity = 10)
      and (select po.status::text from erp.planned_order po where po.id = v_po1) = 'converted'
      and exists (select 1 from erp.production_event pe where pe.works_order_id = v_wo1 and pe.event_kind = 'released')
      and not exists (select 1 from erp.production_event pe where pe.works_order_id = v_wo1 and pe.event_kind = 'held'),
      (select format('%s, standard %s', wo.status, wo.standard_cost_minor) from erp.works_order wo where wo.id = v_wo1);

    -- 2. Short of material: confirmed, and waiting, with the reason.
    v_wo2 := public.erp_firm_planned_order(v_po2, null);
    return query select 'short of material past the policy, the plan is still confirmed and the order waits unreleased, saying why',
      (select wo.status::text in ('draft', 'planned') from erp.works_order wo where wo.id = v_wo2)
      and (select po.status::text from erp.planned_order po where po.id = v_po2) = 'converted'
      and exists (select 1 from erp.production_event pe
                   where pe.works_order_id = v_wo2 and pe.event_kind = 'held' and pe.detail ->> 'why' = 'short'
                     and pe.detail ->> 'reason' like 'CLOVEERP_MATERIAL_SHORTAGE:%')
      and not exists (select 1 from erp.allocation a where a.document_id = v_wo2),
      (select wo.status::text from erp.works_order wo where wo.id = v_wo2);

    -- And released once the material comes.
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_comp, 1000, 100, 'more component');
    perform erp.transition_document(v_grn, 'post');
    perform erp.release_works_order(v_wo2);
    return query select 'the order that waited is released by hand once the material is there',
      (select wo.status::text = 'released' from erp.works_order wo where wo.id = v_wo2),
      (select wo.status::text from erp.works_order wo where wo.id = v_wo2);

    -- 3. Confirmed by a planner, whose role does not release orders.
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    v_wo3 := public.erp_firm_planned_order(v_po3, null);
    begin perform erp.release_works_order(v_wo3); v_err := 'released';
    exception when others then v_err := left(sqlerrm, 120); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    return query select 'a planner who raises orders and does not release them confirms the plan, and the order waits for somebody who does',
      (select wo.status::text in ('draft', 'planned') from erp.works_order wo where wo.id = v_wo3)
      and (select po.status::text from erp.planned_order po where po.id = v_po3) = 'converted'
      and exists (select 1 from erp.production_event pe
                   where pe.works_order_id = v_wo3 and pe.event_kind = 'held'
                     and pe.detail ->> 'why' = 'not_permitted')
      -- Asked, not attempted: nothing was refused, so the access log has
      -- nothing to lose.
      and not exists (select 1 from erp.access_log al
                       where al.tenant_id = r.tenant_id and al.permission_code = 'production.release'
                         and al.object_id = v_wo3 and al.app_user_id = v_planner)
      and v_err like 'CLOVEERP_PERMISSION_DENIED:%',
      v_err;

    -- 4. Confirmed weeks ahead: it waits for its day, and holds no material an
    -- order due sooner needs.
    v_wo4 := public.erp_firm_planned_order(v_po4, null);
    return query select 'a plan confirmed before it is due to start waits unreleased, committing nothing yet',
      (select wo.status::text in ('draft', 'planned') and wo.planned_start = current_date + 30
         from erp.works_order wo where wo.id = v_wo4)
      and exists (select 1 from erp.production_event pe
                   where pe.works_order_id = v_wo4 and pe.event_kind = 'held' and pe.detail ->> 'why' = 'not_due')
      and not exists (select 1 from erp.allocation a where a.document_id = v_wo4),
      (select wo.status::text from erp.works_order wo where wo.id = v_wo4);

    -- 5. Any other refusal still refuses the confirmation.
    begin perform public.erp_firm_planned_order(v_po1, null); v_err := 'firmed';
    exception when others then v_err := left(sqlerrm, 120); end;
    return query select 'a plan already confirmed is refused, as before',
      v_err like 'CLOVEERP_PLANNED_ORDER_ALREADY_FIRMED:%', v_err;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-pof-' || v_hex);
  detail := 'the organisation, its plans and its orders rolled back';
  return next;
end;
$function$;

revoke all on function erp_test.planned_order_firming_suite() from public, anon;

create or replace function erp_test.assert_planned_order_firming_suite()
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
    from erp_test.planned_order_firming_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PLANNED_ORDER_FIRMING_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A planned order confirmed and left in draft with its material there, a shortage that refuses the confirmation, or a planner who releases an order, is the case that failed. Read it.';
  end if;
  if v_total <> 7 then
    raise exception 'CLOVEERP_PLANNED_ORDER_FIRMING_SUITE_SHRANK: % case(s), expected 7', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
end;
$$;

revoke all on function erp_test.assert_planned_order_firming_suite() from public, anon;

comment on function erp_test.assert_planned_order_firming_suite() is
  'A planned order confirmed for a made item is a works order released to the floor, '
  'unless it is not due to start, its material is short past the production policy or '
  'the person confirming does not release orders, when it waits unreleased and says '
  'why (20260925100000).';

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
