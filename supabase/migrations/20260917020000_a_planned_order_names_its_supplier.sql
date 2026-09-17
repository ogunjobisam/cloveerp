-- ─────────────────────────────────────────────────────────────────────────────
-- A planned order names its supplier
--
-- erp.planned_order has carried a supplier_party_id since B7, and
-- erp.firm_planned_order() has always handed it to erp.create_document() as
-- the party. Nothing has ever written it.
--
--     insert into erp.planned_order (
--       tenant_id, entity_id, site_id, item_id, order_kind, quantity,
--       uom_id, required_by, release_on, status, planning_run_id, policy_id)
--
-- Twelve columns, and supplier_party_id is not among them. erp.document.party_id
-- is nullable and nothing refuses a null, so a purchase order firmed from a
-- planning run is created addressed to nobody: no supplier on the document, no
-- supplier on its printed order, and nothing to send it to. It was found on
-- 16 September while wiring erp.item_supplier.split_pct, whose agent noticed
-- that splitting a requirement across suppliers is impossible when planning
-- names no supplier at all.
--
-- The resolver already exists. public.erp_resolve_item_supplier() picks one
-- supplier for a product at a site — site-specific before item-wide, then the
-- default, then preference rank, counting only approved and in-date rows.
-- Planning simply never asked it. But it is a door: it authorises
-- procurement.read, it returns jsonb, and it raises when there is no supplier.
-- None of those three are what a planning run wants, which is probably why it
-- was never called.
--
-- So the choice is lifted out into erp.resolve_item_supplier_row(), which
-- returns the chosen erp.item_supplier row or nothing at all, and the door is
-- re-emitted to build its answer from that row. One rule, asked in three
-- places, rather than the same order-by copied twice and drifting.
--
-- WHAT HAPPENS NOW
--
--   * A planning run writes the supplier it would place a purchase with. A
--     production order has no supplier to name and gets none.
--   * Firming asks again if the plan recorded none — the supplier may have been
--     set up in the days between planning and firming, and refusing over a
--     question that now has an answer would be obtuse.
--   * If there is still no answer, firming refuses by name rather than creating
--     an order addressed to nobody. That is the defect being closed, and
--     leaving a quieter version of it in place would not close it.
--
-- WHAT THIS DOES NOT DO. It does not split a requirement across suppliers.
-- erp.item_supplier.split_pct stays registered as advisory: dividing one
-- requirement needs firming to return several documents instead of one, its
-- door, its screen and its process-flow step. This names one supplier, which is
-- what erp.planned_order has a column for.
--
-- Plans already suggested are not revisited. A planned order raised before this
-- carries no supplier, and firming it resolves one at that moment.
-- ─────────────────────────────────────────────────────────────────────────────

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The choice, lifted out of the door
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.resolve_item_supplier_row(
  p_item_id uuid,
  p_site_id uuid default null,
  p_on      date default null)
returns erp.item_supplier
language sql
stable
security invoker
set search_path = ''
as $$
  -- The supplier for this product here: the one set up for this very site
  -- before one set up for the product anywhere, then whichever is marked the
  -- default, then preference rank. Only approved rows, only in-date ones.
  -- Returns no row rather than refusing; the caller decides what silence means.
  select s.*
    from erp.item_supplier s
   where s.tenant_id = erp.require_tenant_id()
     and s.item_id = p_item_id
     and s.status = 'active'
     and s.is_approved_for_use
     and s.valid_from <= coalesce(p_on, current_date)
     and (s.valid_to is null or s.valid_to > coalesce(p_on, current_date))
     and (s.site_id is null or p_site_id is null or s.site_id = p_site_id)
   order by (s.site_id is not null and s.site_id = p_site_id) desc,
            s.is_default desc, s.preference_rank
   limit 1;
$$;

comment on function erp.resolve_item_supplier_row(uuid, uuid, date) is
  'The one supplier a product would be bought from at a site: site-specific '
  'before item-wide, then the default, then preference rank, approved and '
  'in-date only. Returns nothing when none is set up. The single rule behind '
  'public.erp_resolve_item_supplier(), erp.run_planning() and '
  'erp.firm_planned_order().';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The door now asks the same question
-- ═════════════════════════════════════════════════════════════════════════════
--
-- This door has exactly one definition (20260830132704) and one mechanical
-- rewrite since (20260904980000, which carried its refusal from the retired
-- prefix to CLOVEERP_). There is no other patch to lose, and the assertion
-- below proves that is still true before the body is replaced.

do $door$
declare
  v_def constant text := pg_get_functiondef('public.erp_resolve_item_supplier(uuid,uuid)'::regprocedure);
begin
  if position('erp.resolve_item_supplier_row(' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: public.erp_resolve_item_supplier already asks the shared rule';
  end if;
  if position('CLOVEERP_NO_SUPPLIER' in v_def) = 0
     or position('order by (s.site_id is not null and s.site_id = p_site_id) desc,' in v_def) = 0 then
    raise exception
      'CLOVEERP_BODY_UNRECOGNISED: public.erp_resolve_item_supplier is not the 20260830132704 body as rewritten by 20260904980000';
  end if;
end
$door$;

create or replace function public.erp_resolve_item_supplier(
  p_item_id uuid,
  p_site_id uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  s     erp.item_supplier;
  v_out jsonb;
begin
  perform erp.authorise('procurement.read');

  s := erp.resolve_item_supplier_row(p_item_id, p_site_id, current_date);

  if s.id is null then
    raise exception 'CLOVEERP_NO_SUPPLIER: no supplier is configured for this item here'
      using errcode = 'P0002';
  end if;

  select jsonb_build_object(
    'item_supplier_id', s.id, 'party_id', s.party_id, 'supplier', p.name,
    'site_id', s.site_id, 'scope', case when s.site_id is null then 'item' else 'site' end,
    'preference_rank', s.preference_rank, 'is_default', s.is_default,
    'split_pct', s.split_pct, 'lead_time_days', s.lead_time_days,
    'min_order_quantity', s.min_order_quantity,
    'approved', coalesce(bool_or(r.is_approved), false))
    into v_out
    from erp.party p
    left join erp.party_role r
      on r.tenant_id = p.tenant_id and r.party_id = p.id
     and r.role_kind = 'supplier' and r.status = 'active'
   where p.tenant_id = erp.require_tenant_id() and p.id = s.party_id
   group by p.name;

  return v_out;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. What firming should be handed
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.planned_order_supplier(p_planned_order_id uuid)
returns uuid
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  po erp.planned_order;
  s  erp.item_supplier;
begin
  select * into po from erp.planned_order
   where tenant_id = erp.require_tenant_id() and id = p_planned_order_id;

  -- A works order has no supplier, and firming one never reaches here.
  if not found or po.order_kind <> 'purchase' then
    return null;
  end if;

  if po.supplier_party_id is not null then
    return po.supplier_party_id;
  end if;

  -- The plan named nobody. Ask again rather than refuse: a supplier set up in
  -- the days between planning and firming is an answer, and the plan is not
  -- rerun just to notice it.
  s := erp.resolve_item_supplier_row(po.item_id, po.site_id, current_date);

  if s.party_id is null then
    raise exception
      'CLOVEERP_PLANNED_ORDER_HAS_NO_SUPPLIER: % is for a product with no supplier set up at this site',
      p_planned_order_id
      using errcode = 'P0002',
            hint = 'Set the supplier on the product''s supply, then firm the order again.';
  end if;

  return s.party_id;
end;
$$;

comment on function erp.planned_order_supplier(uuid) is
  'The supplier a planned purchase becomes an order to: the one the plan '
  'recorded, otherwise the one that would be resolved today, otherwise a '
  'refusal — never a purchase order addressed to nobody.';

select erp.register_refusal(
  'CLOVEERP_PLANNED_ORDER_HAS_NO_SUPPLIER',
  'Firming a planned purchase for a product with no supplier',
  'A purchase order has to be addressed to somebody before it can be sent, priced or matched. The plan named no supplier and none is set up for this product at this site, so firming it would produce an order nobody could place.',
  'Set the supplier on the product''s supply — master data, the product, who supplies it — then firm the order again. If the product is made rather than bought, it needs a bill of materials so planning raises a works order instead.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Planning writes it, firming asks for it
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Both are needle-patched against the live bodies. erp.run_planning is the
-- 20260906134000 body with no patch since. erp.firm_planned_order is the
-- 20260906133000 body as patched by 20260906134000 (the scenario refusal, which
-- sits just after the authorise) and by 20260914040000 (the line description).
-- Neither needle touches either of those, and both are asserted intact after.

do $planning$
declare
  v_sig    constant text := 'erp.run_planning(uuid,integer,uuid,text,jsonb,text)';
  v_def    text := pg_get_functiondef('erp.run_planning(uuid,integer,uuid,text,jsonb,text)'::regprocedure);
  v_needle constant text :=
       E'            insert into erp.planned_order (\n'
    || E'              tenant_id, entity_id, site_id, item_id, order_kind, quantity,\n'
    || E'              uom_id, required_by, release_on, status, planning_run_id, policy_id)\n'
    || E'            values (v_tenant, v_entity, p_site_id, r.item_id, v_kind, v_qty,\n'
    || E'                    v_uom, d.due_on, v_release, ''suggested'', v_run, pp.id)\n';
  v_new    constant text :=
       E'            -- A purchase the plan suggests names the supplier it would be\n'
    || E'            -- placed with, so firming it produces an order addressed to\n'
    || E'            -- somebody. Something made here has no supplier to name.\n'
    || E'            insert into erp.planned_order (\n'
    || E'              tenant_id, entity_id, site_id, item_id, order_kind, quantity,\n'
    || E'              uom_id, required_by, release_on, status, planning_run_id, policy_id,\n'
    || E'              supplier_party_id)\n'
    || E'            values (v_tenant, v_entity, p_site_id, r.item_id, v_kind, v_qty,\n'
    || E'                    v_uom, d.due_on, v_release, ''suggested'', v_run, pp.id,\n'
    || E'                    case when v_kind = ''purchase''\n'
    || E'                         then (erp.resolve_item_supplier_row(r.item_id, p_site_id, current_date)).party_id\n'
    || E'                    end)\n';
begin
  if position('supplier_party_id' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % already names a supplier', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception
      'CLOVEERP_BODY_UNRECOGNISED: % does not write its planned order exactly once the way the 20260906134000 body does', v_sig;
  end if;

  execute replace(v_def, v_needle, v_new);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('erp.resolve_item_supplier_row(r.item_id, p_site_id, current_date)' in v_def) = 0
     or position('insert into erp.planned_order_peg (' in v_def) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without the supplier, or without its pegging', v_sig;
  end if;
end
$planning$;

do $firming$
declare
  v_sig    constant text := 'erp.firm_planned_order(uuid,text)';
  v_def    text := pg_get_functiondef('erp.firm_planned_order(uuid,text)'::regprocedure);
  v_needle constant text :=
    E'    p_document_type_code, po.entity_id, po.site_id, po.supplier_party_id,\n';
  v_new    constant text :=
    E'    p_document_type_code, po.entity_id, po.site_id, erp.planned_order_supplier(po.id),\n';
begin
  if position('erp.planned_order_supplier(' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % already asks who the order is for', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception
      'CLOVEERP_BODY_UNRECOGNISED: % does not raise its document exactly once the way the 20260906133000 body does', v_sig;
  end if;

  execute replace(v_def, v_needle, v_new);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('erp.planned_order_supplier(po.id)' in v_def) = 0
     or position('CLOVEERP_SCENARIO_ORDER_NOT_FIRMED' in v_def) = 0
     or position('erp.line_description(po.item_id, null)' in v_def) = 0 then
    raise exception
      'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without the supplier, or without the scenario refusal or line description it already had', v_sig;
  end if;
end
$firming$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.planned_supplier_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_site uuid; v_item uuid; v_orphan uuid; v_supp uuid; v_other uuid;
  v_uom uuid; v_entity uuid;
  v_po uuid; v_po2 uuid; v_doc uuid;
  v_ok boolean; v_msg text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-planned-supplier', 'Planned supplier suite',
                              'admin@zz-planned-supplier.test', 'Planned Supplier Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000f0', 'admin@zz-planned-supplier.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000f0')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select l.entity_id into v_entity
    from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant order by s.code limit 1;
  select u.id into v_uom from erp.uom u where u.tenant_id = v_tenant order by u.code limit 1;
  select i.id into v_item from erp.item i
   where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status order by i.code limit 1;
  select p.id into v_supp from erp.party p
    join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
     and pr.role_kind = 'supplier' and pr.status = 'active'
   where p.tenant_id = v_tenant order by p.code limit 1;

  -- A second supplier, so preference is a choice rather than the only row.
  insert into erp.party (tenant_id, code, name, status)
  values (v_tenant, 'ZZPS-OTHER', 'The other supplier', 'active'::erp.record_status)
  returning id into v_other;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (v_tenant, v_other, 'supplier', 'active');

  -- A product nobody supplies, to prove the refusal.
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (v_tenant, 'ZZPS-ORPHAN', 'Nobody supplies this', v_uom, 'active'::erp.record_status)
  returning id into v_orphan;

  insert into erp.item_supplier (tenant_id, item_id, party_id, preference_rank,
                                 is_default, is_approved_for_use, status, valid_from)
  values (v_tenant, v_item, v_other, 9, false, true, 'active'::erp.record_status, current_date - 1),
         (v_tenant, v_item, v_supp,  1, true,  true, 'active'::erp.record_status, current_date - 1);

  -- ── 1. The rule picks the default ahead of the also-ran ──────────────────
  v_cases := v_cases + 1;
  case_name := 'the shared rule picks the default supplier, not merely the first row';
  passed := (erp.resolve_item_supplier_row(v_item, v_site, current_date)).party_id = v_supp;
  detail := format('chose %s, expected the default %s',
                   coalesce((erp.resolve_item_supplier_row(v_item, v_site, current_date)).party_id::text, 'nobody'),
                   v_supp::text);
  return next;

  -- ── 2. And says nothing rather than refusing when there is nobody ────────
  v_cases := v_cases + 1;
  case_name := 'the rule returns nothing for a product nobody supplies';
  passed := (erp.resolve_item_supplier_row(v_orphan, v_site, current_date)).party_id is null;
  detail := 'silence, not a refusal';
  return next;

  -- ── 3. An out-of-date row is not a supplier ──────────────────────────────
  v_cases := v_cases + 1;
  update erp.item_supplier set valid_to = current_date - 1
   where tenant_id = v_tenant and item_id = v_item and party_id = v_supp;
  case_name := 'a supply arrangement that has expired is passed over for the next one';
  passed := (erp.resolve_item_supplier_row(v_item, v_site, current_date)).party_id = v_other;
  detail := 'the expired default gave way to the other supplier';
  return next;
  update erp.item_supplier set valid_to = null
   where tenant_id = v_tenant and item_id = v_item and party_id = v_supp;

  -- ── 4. The door answers from the same rule ───────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the door and the rule name the same supplier';
  passed := (public.erp_resolve_item_supplier(v_item, v_site) ->> 'party_id')::uuid = v_supp
        and (public.erp_resolve_item_supplier(v_item, v_site) ->> 'supplier') is not null;
  detail := coalesce(public.erp_resolve_item_supplier(v_item, v_site) ->> 'supplier', 'no name');
  return next;

  -- ── 5. And still refuses when there is nobody ────────────────────────────
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    perform public.erp_resolve_item_supplier(v_orphan, v_site);
    v_msg := 'the door answered for a product nobody supplies';
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'the door still refuses for a product nobody supplies';
  passed := v_msg like 'CLOVEERP_NO_SUPPLIER%';
  detail := left(coalesce(v_msg, 'no verdict'), 120);
  return next;

  -- ── 6. A plan names the supplier it would buy from ───────────────────────
  v_cases := v_cases + 1;
  insert into erp.planned_order (tenant_id, entity_id, site_id, item_id, order_kind,
                                 quantity, uom_id, required_by, release_on, status,
                                 supplier_party_id)
  values (v_tenant, v_entity, v_site, v_item, 'purchase', 10, v_uom,
          current_date + 7, current_date, 'suggested',
          (erp.resolve_item_supplier_row(v_item, v_site, current_date)).party_id)
  returning id into v_po;
  case_name := 'a planned purchase records the supplier it would be placed with';
  passed := (select po.supplier_party_id from erp.planned_order po where po.id = v_po) = v_supp;
  detail := 'the column planning had never written';
  return next;

  -- ── 7. Firming hands that supplier to the document ───────────────────────
  v_cases := v_cases + 1;
  case_name := 'what firming is handed is the supplier the plan recorded';
  passed := erp.planned_order_supplier(v_po) = v_supp;
  detail := 'recorded, so not asked again';
  return next;

  -- ── 8. A plan that named nobody is asked again, not refused ──────────────
  v_cases := v_cases + 1;
  insert into erp.planned_order (tenant_id, entity_id, site_id, item_id, order_kind,
                                 quantity, uom_id, required_by, release_on, status)
  values (v_tenant, v_entity, v_site, v_item, 'purchase', 5, v_uom,
          current_date + 7, current_date, 'suggested')
  returning id into v_po2;
  case_name := 'a plan raised before the supplier existed is asked again rather than refused';
  passed := erp.planned_order_supplier(v_po2) = v_supp;
  detail := 'resolved at firming, not at planning';
  return next;

  -- ── 9. And refuses rather than addressing an order to nobody ─────────────
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    insert into erp.planned_order (tenant_id, entity_id, site_id, item_id, order_kind,
                                   quantity, uom_id, required_by, release_on, status)
    values (v_tenant, v_entity, v_site, v_orphan, 'purchase', 5, v_uom,
            current_date + 7, current_date, 'suggested')
    returning id into v_doc;
    perform erp.planned_order_supplier(v_doc);
    v_msg := 'an order for a product nobody supplies was addressed to nobody';
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'firming refuses rather than raising a purchase order addressed to nobody';
  passed := v_msg like 'CLOVEERP_PLANNED_ORDER_HAS_NO_SUPPLIER%';
  detail := left(coalesce(v_msg, 'no verdict'), 140);
  return next;

  -- ── 10. The refusal says what to do about it ─────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the refusal is registered and names its next action';
  passed := exists (select 1 from erp_ref.refusal r
                     where r.code = 'CLOVEERP_PLANNED_ORDER_HAS_NO_SUPPLIER'
                       and length(btrim(r.next_action)) > 0)
        and exists (select 1 from erp_ref.resource x
                     where x.key = erp_ref.refusal_key('CLOVEERP_PLANNED_ORDER_HAS_NO_SUPPLIER', 'next_action')
                       and x.locale = 'en');
  detail := 'registered and mirrored into the resource layer';
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- ── 11. Undone ───────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-planned-supplier')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000f0');
  detail := 'zz-planned-supplier rolled back with its suppliers and its plans';
  return next;

  if v_cases <> 11 then
    raise exception 'CLOVEERP_SUITE_SHRANK: planned_supplier_suite ran % cases, expected 11', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.planned_supplier_suite() from public, anon;

create or replace function erp_test.assert_planned_supplier_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _planned_supplier on commit drop as
    select * from erp_test.planned_supplier_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _planned_supplier;
  drop table _planned_supplier;
  if v_fail > 0 then
    raise exception E'CLOVEERP_PLANNED_SUPPLIER_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 11 then
    raise exception 'CLOVEERP_SUITE_SHRANK: planned_supplier_suite ran % cases, expected 11', v_all;
  end if;
  return format('a planned order names its supplier: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_planned_supplier_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_planned_supplier_suite();

select erp.assert_write_only_columns();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
