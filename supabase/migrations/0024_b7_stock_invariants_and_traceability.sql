-- =============================================================================
-- ERPWare — B7 (part 3/5): movement types, traceability, and the invariant suite
--
-- Spec Part 8, B7: "with invariant tests as first-class artefacts".
--
-- The stock invariants in spec 4.4 are the kind that hold on the day they are
-- written and quietly stop holding two releases later. So they are callable
-- assertions that run on every build, not prose:
--
--   erp.assert_stock_reconciles()   on-hand equals the sum of movements
--   erp.assert_batch_genealogy()    lineage is continuous and acyclic
--   erp_test.stock_invariant_suite() the behavioural half — that the ledger
--                                   refuses edits, refuses to go negative
--                                   except where authorised, and refuses to
--                                   let control flags contradict the stock
--
-- Spec 4.8 also demands: "given any batch, the complete downstream despatch set
-- and upstream component set are retrievable as a query, at any time". That is
-- a recall requirement with a clock attached, so it is a query rather than a
-- report someone assembles.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Movement types (product content)
--
-- The `allows_negative` column is the specification's "explicitly authorised
-- movement types" made into a list. Two entries carry it, both deliberate:
-- a count adjustment records what is actually on the shelf, including when
-- that is less than the system believed; and an emergency issue exists for
-- sites that must ship before the paperwork catches up. Everything else
-- refuses.
-- -----------------------------------------------------------------------------

insert into erp_ref.movement_type
  (code, name_key, direction, module_code, allows_negative, requires_reason, affects_valuation, is_system, description) values
  ('goods_receipt',      'movement.goods_receipt',      'in',            'procurement', false, false, true,  false, 'Receipt against a purchase order.'),
  ('receipt_no_order',   'movement.receipt_no_order',   'in',            'inventory',   false, true,  true,  false, 'Receipt without a purchase order; needs a reason.'),
  ('return_from_customer','movement.return_from_customer','in',          'sales',       false, true,  true,  false, 'Goods coming back from a customer.'),
  ('production_output',  'movement.production_output',  'in',            'production',  false, false, true,  false, 'Finished goods from a works order.'),
  ('putaway',            'movement.putaway',            'transfer',      'inventory',   false, false, false, false, 'Receiving area to a storage location.'),
  ('internal_transfer',  'movement.internal_transfer',  'transfer',      'inventory',   false, false, false, false, 'Between locations at one site.'),
  ('replenishment',      'movement.replenishment',      'transfer',      'inventory',   false, false, false, false, 'Bulk to pick face.'),
  ('container_move',     'movement.container_move',     'transfer',      'inventory',   false, false, false, true,  'Generated when a handling unit moves; carries its contents.'),
  ('pick',               'movement.pick',               'transfer',      'sales',       false, false, false, false, 'Storage to staging against an order.'),
  ('despatch',           'movement.despatch',           'out',           'sales',       false, false, true,  false, 'Goods leaving the site to a customer.'),
  ('production_issue',   'movement.production_issue',   'out',           'production',  false, false, true,  false, 'Components consumed by a works order.'),
  ('return_to_supplier', 'movement.return_to_supplier', 'out',           'procurement', false, true,  true,  false, 'Goods going back to a supplier.'),
  ('scrap',              'movement.scrap',              'out',           'inventory',   false, true,  true,  false, 'Written off; needs a reason.'),
  ('status_change',      'movement.status_change',      'status_change', 'quality',     false, true,  false, false, 'Quarantine release, block, or hold. Same place, different condition.'),
  ('count_adjustment',   'movement.count_adjustment',   'transfer',      'inventory',   true,  true,  true,  false,
   'Reconciles the system to a physical count. Authorised to go negative: the shelf is the fact, and refusing to record a shortfall does not make the stock exist.'),
  ('emergency_issue',    'movement.emergency_issue',    'out',           'inventory',   true,  true,  true,  false,
   'Issue ahead of the paperwork. Authorised to go negative so operations are never blocked by a receipt that has not been keyed; the resulting negative is an exception someone must clear.')
on conflict (code) do nothing;

insert into erp_ref.resource (key, locale, value) values
  ('movement.goods_receipt','en','Goods receipt'),
  ('movement.receipt_no_order','en','Receipt without order'),
  ('movement.return_from_customer','en','Customer return'),
  ('movement.production_output','en','Production output'),
  ('movement.putaway','en','Putaway'),
  ('movement.internal_transfer','en','Internal transfer'),
  ('movement.replenishment','en','Replenishment'),
  ('movement.container_move','en','Container move'),
  ('movement.pick','en','Pick'),
  ('movement.despatch','en','Despatch'),
  ('movement.production_issue','en','Production issue'),
  ('movement.return_to_supplier','en','Return to supplier'),
  ('movement.scrap','en','Scrap'),
  ('movement.status_change','en','Stock status change'),
  ('movement.count_adjustment','en','Count adjustment'),
  ('movement.emergency_issue','en','Emergency issue')
on conflict (key, locale) do nothing;

-- -----------------------------------------------------------------------------
-- Invariant: on-hand equals the sum of movements
-- -----------------------------------------------------------------------------

create or replace function erp.stock_reconciliation_report()
returns table (
  site_id      uuid,
  location_id  uuid,
  item_id      uuid,
  batch_id     uuid,
  stock_status erp.stock_status,
  ledger_quantity  numeric,
  cached_quantity  numeric,
  difference       numeric
)
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(p.site_id, b.site_id),
         coalesce(p.location_id, b.location_id),
         coalesce(p.item_id, b.item_id),
         coalesce(p.batch_id, b.batch_id),
         coalesce(p.stock_status, b.stock_status),
         coalesce(p.quantity, 0),
         coalesce(b.quantity, 0),
         coalesce(p.quantity, 0) - coalesce(b.quantity, 0)
    from erp.stock_position p
    full outer join erp.stock_balance b
      on b.tenant_id = p.tenant_id
     and b.site_id = p.site_id
     and b.location_id = p.location_id
     and b.item_id = p.item_id
     and b.batch_id is not distinct from p.batch_id
     and b.serial_id is not distinct from p.serial_id
     and b.container_id is not distinct from p.container_id
     and b.stock_status = p.stock_status
   where coalesce(p.tenant_id, b.tenant_id) = erp.require_tenant_id()
     and coalesce(p.quantity, 0) is distinct from coalesce(b.quantity, 0)
$$;

create or replace function erp.assert_stock_reconciles()
returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_count integer;
  v_detail text;
begin
  select count(*), string_agg(format('  item %s batch %s at %s: ledger %s, cached %s',
                                     r.item_id, coalesce(r.batch_id::text, '-'),
                                     r.location_id, r.ledger_quantity, r.cached_quantity),
                              E'\n')
    into v_count, v_detail
    from erp.stock_reconciliation_report() r;

  if v_count > 0 then
    raise exception
      E'ERPWARE_STOCK_DOES_NOT_RECONCILE: % position(s) where the cache disagrees with the ledger\n%',
      v_count, v_detail;
  end if;

  return 'stock: every cached balance equals the sum of its movements';
end;
$$;

comment on function erp.assert_stock_reconciles() is
  'Spec 4.4: on-hand quantity equals the sum of movements, always. The cache '
  'exists for speed; this is what stops it becoming a second opinion.';

-- -----------------------------------------------------------------------------
-- Traceability (spec 4.8)
--
-- "given any batch, the complete downstream despatch set and upstream
--  component set are retrievable as a query, at any time"
-- -----------------------------------------------------------------------------

create or replace function erp.trace_batch_upstream(p_batch_id uuid)
returns table (depth integer, batch_id uuid, item_id uuid, batch_number text,
               supplier_lot text, supplier_party_id uuid, expires_on date)
language sql
stable
security invoker
set search_path = ''
as $$
  with recursive up as (
    select 0 as depth, b.id as batch_id
      from erp.batch b
     where b.tenant_id = erp.require_tenant_id() and b.id = p_batch_id
    union
    select u.depth + 1, g.parent_batch_id
      from up u
      join erp.batch_genealogy g
        on g.tenant_id = erp.current_tenant_id() and g.child_batch_id = u.batch_id
     where u.depth < 50
  )
  select u.depth, b.id, b.item_id, b.batch_number, b.supplier_lot,
         b.supplier_party_id, b.expires_on
    from up u
    join erp.batch b on b.id = u.batch_id
   order by u.depth, b.batch_number
$$;

create or replace function erp.trace_batch_downstream(p_batch_id uuid)
returns table (depth integer, batch_id uuid, item_id uuid, batch_number text)
language sql
stable
security invoker
set search_path = ''
as $$
  with recursive down as (
    select 0 as depth, b.id as batch_id
      from erp.batch b
     where b.tenant_id = erp.require_tenant_id() and b.id = p_batch_id
    union
    select d.depth + 1, g.child_batch_id
      from down d
      join erp.batch_genealogy g
        on g.tenant_id = erp.current_tenant_id() and g.parent_batch_id = d.batch_id
     where d.depth < 50
  )
  select d.depth, b.id, b.item_id, b.batch_number
    from down d
    join erp.batch b on b.id = d.batch_id
   order by d.depth, b.batch_number
$$;

-- The recall question: everything that left the building carrying this batch,
-- or anything made from it. This is the query a regulator's clock is running
-- against, so it walks genealogy first and then despatch movements in one go.
create or replace function erp.trace_batch_despatches(p_batch_id uuid)
returns table (
  movement_id   bigint,
  occurred_at   timestamptz,
  batch_id      uuid,
  batch_number  text,
  item_id       uuid,
  quantity      numeric,
  document_id   uuid,
  site_id       uuid,
  movement_type text)
language sql
stable
security invoker
set search_path = ''
as $$
  select m.id, m.occurred_at, m.batch_id, b.batch_number, m.item_id, m.quantity,
         m.document_id, m.site_id, m.movement_type
    from erp.trace_batch_downstream(p_batch_id) d
    join erp.stock_movement m
      on m.tenant_id = erp.current_tenant_id() and m.batch_id = d.batch_id
    join erp.batch b on b.id = m.batch_id
    join erp_ref.movement_type mt on mt.code = m.movement_type
   where mt.direction = 'out'
     and not m.is_reversal
     -- A despatch that was reversed did not leave.
     and not exists (select 1 from erp.stock_movement r
                      where r.tenant_id = m.tenant_id and r.reverses_movement_id = m.id)
   order by m.occurred_at
$$;

comment on function erp.trace_batch_despatches(uuid) is
  'Spec 4.8: the complete downstream despatch set for a batch, as a query. '
  'Walks genealogy so that a recall of a raw material finds the finished goods '
  'made from it, and excludes reversed movements because those never left.';

-- Genealogy must be continuous and acyclic (spec 4.4).
create or replace function erp.assert_batch_genealogy()
returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cycles integer;
  v_orphan integer;
begin
  -- A batch that is its own ancestor makes every trace non-terminating.
  with recursive walk as (
    select g.parent_batch_id as root, g.child_batch_id as node, 1 as depth
      from erp.batch_genealogy g where g.tenant_id = v_tenant
    union all
    select w.root, g.child_batch_id, w.depth + 1
      from walk w
      join erp.batch_genealogy g
        on g.tenant_id = v_tenant and g.parent_batch_id = w.node
     where w.depth < 50
  )
  select count(*) into v_cycles from walk where root = node;

  if v_cycles > 0 then
    raise exception 'ERPWARE_GENEALOGY_CYCLE: % batch(es) are their own ancestor', v_cycles;
  end if;

  -- Genealogy pointing at a batch that no longer exists would be a break in
  -- the chain. Foreign keys prevent it; this proves they were not dropped.
  select count(*) into v_orphan
    from erp.batch_genealogy g
   where g.tenant_id = v_tenant
     and (not exists (select 1 from erp.batch b where b.id = g.parent_batch_id)
       or not exists (select 1 from erp.batch b where b.id = g.child_batch_id));

  if v_orphan > 0 then
    raise exception 'ERPWARE_GENEALOGY_BROKEN: % link(s) reference a missing batch', v_orphan;
  end if;

  return 'genealogy: continuous and acyclic';
end;
$$;

-- -----------------------------------------------------------------------------
-- The behavioural suite
-- -----------------------------------------------------------------------------

create or replace function erp_test.stock_invariant_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_ent uuid; v_site uuid; v_bulk uuid; v_pick uuid; v_qa uuid;
  v_uom uuid; v_item uuid; v_plain uuid;
  v_batch uuid; v_child uuid;
  v_ct_pallet uuid; v_ct_case uuid;
  v_mv bigint; v_rev bigint;
  v_n numeric; v_c bigint;
begin
  insert into erp.tenant (code, name, status)
  values ('zz-stock-' || substr(gen_random_uuid()::text, 1, 8), 'Stock invariants', 'active')
  returning id into v_tenant;
  perform erp.set_job_tenant(v_tenant);

  insert into erp.entity (tenant_id, code, name, base_currency)
  values (v_tenant, 'E1', 'Entity', 'GBP') returning id into v_ent;
  insert into erp.site (tenant_id, entity_id, code, name, site_type)
  values (v_tenant, v_ent, 'S1', 'Site', 'warehouse') returning id into v_site;
  insert into erp.location (tenant_id, site_id, code, location_type)
  values (v_tenant, v_site, 'BULK', 'bulk') returning id into v_bulk;
  insert into erp.location (tenant_id, site_id, code, location_type)
  values (v_tenant, v_site, 'PICK', 'pick') returning id into v_pick;
  insert into erp.location (tenant_id, site_id, code, location_type)
  values (v_tenant, v_site, 'QA', 'quarantine') returning id into v_qa;

  insert into erp.uom (tenant_id, code, name, uom_class, is_base)
  values (v_tenant, 'EA', 'Each', 'quantity', true) returning id into v_uom;

  insert into erp.item (tenant_id, code, name, lifecycle, is_batch_controlled,
                        has_expiry, stock_uom_id)
  values (v_tenant, 'ITEM-B', 'Batched item', 'active', true, true, v_uom)
  returning id into v_item;
  insert into erp.item (tenant_id, code, name, lifecycle, stock_uom_id)
  values (v_tenant, 'ITEM-P', 'Plain item', 'active', v_uom) returning id into v_plain;

  insert into erp.batch (tenant_id, item_id, batch_number, status, expires_on)
  values (v_tenant, v_item, 'B001', 'unrestricted', current_date + 90)
  returning id into v_batch;
  insert into erp.batch (tenant_id, item_id, batch_number, status, expires_on)
  values (v_tenant, v_item, 'B002-child', 'unrestricted', current_date + 60)
  returning id into v_child;

  -- --- receipts and the reconciliation invariant -----------------------------
  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
    to_location_id, to_status, quantity, uom_id)
  values (v_tenant, v_ent, v_site, 'goods_receipt', v_item, v_batch,
          v_bulk, 'available', 100, v_uom)
  returning id into v_mv;

  case_name := 'a receipt creates the position it says it does';
  select b.quantity into v_n from erp.stock_balance b
   where b.item_id = v_item and b.location_id = v_bulk and b.stock_status = 'available';
  passed := (v_n = 100);
  detail := format('on hand %s', coalesce(v_n, 0));
  return next;

  case_name := 'the cached balance equals the sum of movements';
  begin
    perform erp.assert_stock_reconciles();
    passed := true; detail := 'reconciled';
  exception when others then
    passed := false; detail := sqlerrm;
  end;
  return next;

  -- --- the ledger refuses edits ---------------------------------------------
  case_name := 'a movement cannot be edited';
  begin
    update erp.stock_movement set quantity = 999 where id = v_mv;
    passed := false; detail := 'the ledger accepted an update';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  case_name := 'a movement cannot be deleted';
  begin
    delete from erp.stock_movement where id = v_mv;
    passed := false; detail := 'the ledger accepted a delete';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  case_name := 'the derived balance cannot be written directly';
  begin
    update erp.stock_balance set quantity = 5000
     where item_id = v_item and location_id = v_bulk;
    passed := false; detail := 'a balance was typed in';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  -- --- corrections are reversals --------------------------------------------
  case_name := 'a correction is a reversing movement, and it nets to zero';
  v_rev := erp.reverse_stock_movement(v_mv, 'keyed twice');
  select b.quantity into v_n from erp.stock_balance b
   where b.item_id = v_item and b.location_id = v_bulk and b.stock_status = 'available';
  passed := (v_n = 0)
            and exists (select 1 from erp.stock_movement where id = v_mv)
            and exists (select 1 from erp.stock_movement where id = v_rev and is_reversal);
  detail := format('position %s, both movements still present', coalesce(v_n, 0));
  return next;

  case_name := 'the same movement cannot be reversed twice';
  begin
    perform erp.reverse_stock_movement(v_mv, 'again');
    passed := false; detail := 'a second reversal was accepted';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  -- --- negative stock --------------------------------------------------------
  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
    to_location_id, to_status, quantity, uom_id)
  values (v_tenant, v_ent, v_site, 'goods_receipt', v_item, v_batch,
          v_bulk, 'available', 10, v_uom);

  case_name := 'an ordinary movement cannot drive a position negative';
  begin
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
      from_location_id, from_status, quantity, uom_id)
    values (v_tenant, v_ent, v_site, 'despatch', v_item, v_batch,
            v_bulk, 'available', 50, v_uom);
    passed := false; detail := 'despatch of 50 against 10 was accepted';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  case_name := 'an authorised movement type may drive a position negative';
  begin
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
      from_location_id, from_status, quantity, uom_id, reason_code)
    values (v_tenant, v_ent, v_site, 'emergency_issue', v_item, v_batch,
            v_bulk, 'available', 50, v_uom, 'line down');
    select b.quantity into v_n from erp.stock_balance b
     where b.item_id = v_item and b.location_id = v_bulk and b.stock_status = 'available';
    passed := (v_n = -40);
    detail := format('position %s', v_n);
  exception when others then
    passed := false; detail := sqlerrm;
  end;
  return next;

  -- put it back, so later cases start from a sane position
  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
    to_location_id, to_status, quantity, uom_id)
  values (v_tenant, v_ent, v_site, 'goods_receipt', v_item, v_batch,
          v_bulk, 'available', 140, v_uom);

  -- --- status is a ledger dimension, not a flag ------------------------------
  case_name := 'a status change moves quantity between conditions, not places';
  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
    from_location_id, from_status, to_location_id, to_status, quantity, uom_id, reason_code)
  values (v_tenant, v_ent, v_site, 'status_change', v_item, v_batch,
          v_bulk, 'available', v_bulk, 'quarantine', 40, v_uom, 'sampling');
  select b.quantity into v_n from erp.stock_balance b
   where b.item_id = v_item and b.location_id = v_bulk and b.stock_status = 'quarantine';
  passed := (v_n = 40);
  detail := format('quarantined %s at the same location', coalesce(v_n, 0));
  return next;

  -- --- control flags versus reality ------------------------------------------
  case_name := 'batch control cannot be turned off while batched stock exists';
  begin
    update erp.item set is_batch_controlled = false, has_expiry = false where id = v_item;
    passed := false; detail := 'the flag was changed';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  case_name := 'a batch is required for a batch-controlled item';
  begin
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id,
      to_location_id, to_status, quantity, uom_id)
    values (v_tenant, v_ent, v_site, 'goods_receipt', v_item, v_bulk, 'available', 1, v_uom);
    passed := false; detail := 'a batchless movement was accepted';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  case_name := 'a batch is refused for an item that is not batch controlled';
  begin
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
      to_location_id, to_status, quantity, uom_id)
    values (v_tenant, v_ent, v_site, 'goods_receipt', v_plain, v_batch,
            v_bulk, 'available', 1, v_uom);
    passed := false; detail := 'a batch was accepted on an unbatched item';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  -- --- containers ------------------------------------------------------------
  insert into erp.container (tenant_id, code, container_type, site_id, location_id)
  values (v_tenant, 'PAL-1', 'pallet', v_site, v_bulk) returning id into v_ct_pallet;
  insert into erp.container (tenant_id, code, container_type, parent_container_id,
                             site_id, location_id)
  values (v_tenant, 'CASE-1', 'case', v_ct_pallet, v_site, v_bulk) returning id into v_ct_case;

  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, batch_id, container_id,
    to_location_id, to_status, quantity, uom_id)
  values (v_tenant, v_ent, v_site, 'goods_receipt', v_item, v_batch, v_ct_case,
          v_bulk, 'available', 24, v_uom);

  case_name := 'moving a container moves everything nested beneath it';
  perform erp.move_container(v_ct_pallet, v_pick, 'staging for despatch');
  select b.quantity into v_n from erp.stock_balance b
   where b.container_id = v_ct_case and b.location_id = v_pick;
  passed := (v_n = 24);
  detail := format('%s moved with the pallet without being addressed directly',
                   coalesce(v_n, 0));
  return next;

  case_name := 'a container cannot become its own ancestor';
  begin
    update erp.container set parent_container_id = v_ct_case where id = v_ct_pallet;
    passed := false; detail := 'a container cycle was accepted';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  -- --- genealogy and traceability --------------------------------------------
  insert into erp.batch_genealogy (tenant_id, parent_batch_id, child_batch_id, quantity)
  values (v_tenant, v_batch, v_child, 10);

  case_name := 'a batch traces upstream to its components';
  select count(*) into v_c from erp.trace_batch_upstream(v_child);
  passed := (v_c = 2);
  detail := format('%s batch(es) in the upstream set', v_c);
  return next;

  case_name := 'a batch traces downstream to what was made from it';
  select count(*) into v_c from erp.trace_batch_downstream(v_batch);
  passed := (v_c = 2);
  detail := format('%s batch(es) in the downstream set', v_c);
  return next;

  case_name := 'genealogy is continuous and acyclic';
  begin
    perform erp.assert_batch_genealogy();
    passed := true; detail := 'no cycles or broken links';
  exception when others then
    passed := false; detail := sqlerrm;
  end;
  return next;

  -- A recall of the parent must find the child's despatches, not just its own.
  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
    to_location_id, to_status, quantity, uom_id)
  values (v_tenant, v_ent, v_site, 'production_output', v_item, v_child,
          v_bulk, 'available', 10, v_uom);
  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
    from_location_id, from_status, quantity, uom_id)
  values (v_tenant, v_ent, v_site, 'despatch', v_item, v_child,
          v_bulk, 'available', 10, v_uom);

  case_name := 'a recall on a component batch finds despatches of what it became';
  select count(*) into v_c from erp.trace_batch_despatches(v_batch)
   where batch_id = v_child;
  passed := (v_c = 1);
  detail := format('%s despatch(es) of the derived batch found from the parent', v_c);
  return next;

  case_name := 'the ledger still reconciles after everything above';
  begin
    perform erp.assert_stock_reconciles();
    passed := true; detail := 'reconciled';
  exception when others then
    passed := false; detail := sqlerrm;
  end;
  return next;

  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();

exception when others then
  perform erp.end_tenant_purge();
  raise;
end;
$$;

create or replace function erp_test.assert_stock_invariants()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not r.passed), count(*),
         string_agg(format('  %s — %s', r.case_name, r.detail), E'\n')
           filter (where not r.passed)
    into v_failed, v_total, v_detail
    from erp_test.stock_invariant_suite() r;

  if v_failed > 0 then
    raise exception E'ERPWARE_STOCK_INVARIANTS_FAILED: %/% case(s) failed\n%',
      v_failed, v_total, v_detail;
  end if;

  return format('stock invariants: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.stock_invariant_suite() from public, anon, authenticated;
revoke all on function erp_test.assert_stock_invariants() from public, anon, authenticated;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_isolation();
select erp.assert_resource_coverage('en');
