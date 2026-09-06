-- =============================================================================
-- 20260906143000  Stock changes hands where it stands, and a policy is
--                 proposed by site
-- -----------------------------------------------------------------------------
-- Specification v1.6 §4.3 (ownership and custody), §5.2, §5.3 (consignment),
-- Part 22 (the interview). Phase 9 of the outstanding-work programme, closing
-- deferred findings 11, 12 and 26.
--
-- Finding 11. A movement carried one owner and one keeper for both of its
-- sides, so a change of owner or keeper in place — consignment consumed,
-- stock handed to a provider — had no shape; 20260906131000's consignment
-- receipt said the goods "stay the supplier's until used" and nothing
-- implemented "until used".
--
--   * Two movement types, ownership_transfer and custody_transfer, and two
--     columns, stock_movement.to_owner_party_id and to_custody_party_id: the
--     to-side of a movement may name another owner or keeper; null means
--     unchanged. The applier, the position view and the reversal follow.
--   * erp.consume_consignment(): the supplier's position becomes the
--     company's at the consigned price, and the value posts — inventory
--     against goods received not invoiced, through the new
--     consignment_consumption rule the inventory installer ships (version 3;
--     an installed organisation upgrades) — because consuming consigned stock
--     is a purchase the supplier will invoice, not a stock adjustment.
--   * erp.hand_over_custody(): the keeper changes, the owner and the
--     valuation do not.
--
-- Finding 12. erp.write_off_stock() resolved the owner to the company, so a
-- write-off against a supplier's position drove the company's empty position
-- negative and was refused; it also relieved cost layers before it knew whose
-- stock it was writing off. It gains an owner and costs only what the company
-- owns. Seven pins held its six-argument signature; the door is dropped and
-- recreated with the seventh, the register names the new signature, and the
-- device handler's six positional arguments still resolve.
--
-- Finding 26. Identity and allocation policy per product class or site had
-- no door and no interview question: the only writer of either was the
-- interview's one organisation-wide answer. Two doors propose a scoped policy
-- as a change-set item — the promoter and manifest already carried class,
-- site and step — a read door lists the policies, and three interview
-- questions ask whether identity or allocation differs by class or site and
-- what it is. A config value scopes to a company or a site, never a class, so
-- the class dimension of allocation is the policy's own keys and the site
-- dimension is its scope; identity policy carries class, site and step on the
-- row.
--
-- Proof: erp_test.consignment_suite() (9 cases, pinned); identity_policy_suite
-- 10 → 11 (a site-scoped policy proposed through the door); costing, ownership,
-- order behaviour, stock invariants, the device kit and the Part 5 register
-- unchanged; the standard assertions and the console.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A movement may change the owner or the keeper where the stock stands
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.movement_type
  (code, name_key, direction, module_code, allows_negative, requires_reason, affects_valuation, is_system, description) values
  ('ownership_transfer', 'movement.ownership_transfer', 'status_change', 'inventory', false, true, true,  false,
   'Stock changes owner where it stands: the same place and condition, another party''s books. Consignment consumed is the common case.'),
  ('custody_transfer',   'movement.custody_transfer',   'status_change', 'inventory', false, true, false, false,
   'Stock changes keeper where it stands; the owner and the valuation do not move.')
on conflict (code) do update set name_key = excluded.name_key, direction = excluded.direction,
  allows_negative = excluded.allows_negative, requires_reason = excluded.requires_reason,
  affects_valuation = excluded.affects_valuation, description = excluded.description;

insert into erp_ref.resource (key, locale, value, module_code) values
  ('movement.ownership_transfer', 'en', 'Change of owner',   'inventory'),
  ('movement.ownership_transfer', 'de', 'Eigentumsübergang', 'inventory'),
  ('movement.custody_transfer',   'en', 'Change of keeper',  'inventory'),
  ('movement.custody_transfer',   'de', 'Verwahrungswechsel', 'inventory')
on conflict (key, locale) do update set value = excluded.value;

alter table erp.stock_movement
  add column if not exists to_owner_party_id   uuid,
  add column if not exists to_custody_party_id uuid;

do $fk$
begin
  if not exists (select 1 from pg_constraint where conname = 'stock_movement_tenant_id_to_owner_party_id_fkey') then
    alter table erp.stock_movement
      add constraint stock_movement_tenant_id_to_owner_party_id_fkey
      foreign key (tenant_id, to_owner_party_id) references erp.party (tenant_id, id) on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'stock_movement_tenant_id_to_custody_party_id_fkey') then
    alter table erp.stock_movement
      add constraint stock_movement_tenant_id_to_custody_party_id_fkey
      foreign key (tenant_id, to_custody_party_id) references erp.party (tenant_id, id) on delete restrict;
  end if;
end
$fk$;

comment on column erp.stock_movement.to_owner_party_id is
  'The owner of the to-side position when it differs from owner_party_id; null means the owner does not change.';
comment on column erp.stock_movement.to_custody_party_id is
  'The keeper of the to-side position when it differs from custody_party_id; null means the keeper does not change.';

-- The applier, restated from 20260906070000: the to-side position is the
-- to-side's owner and keeper. The check first.
do $check$
declare v_def text := pg_get_functiondef('erp.apply_stock_movement()'::regprocedure);
begin
  if (length(v_def) - length(replace(v_def, 'new.serial_id, new.container_id, new.owner_party_id, new.custody_party_id,', ''))) / length('new.serial_id, new.container_id, new.owner_party_id, new.custody_party_id,') <> 2
     or position('first_received_at = case when b.quantity <= 0 then excluded.first_received_at' in v_def) = 0 then
    raise exception 'CLOVEERP_APPLIER_UNRECOGNISED: erp.apply_stock_movement() is not the body this migration restates';
  end if;
end
$check$;

create or replace function erp.apply_stock_movement()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_allows_negative boolean;
  v_requires_reason boolean;
  v_direction       erp.movement_direction;
  v_item            erp.item%rowtype;
  v_resulting       numeric(20,6);
  v_to_owner        uuid := coalesce(new.to_owner_party_id, new.owner_party_id);
  v_to_keeper       uuid := coalesce(new.to_custody_party_id, new.custody_party_id);
begin
  select mt.allows_negative, mt.requires_reason, mt.direction
    into v_allows_negative, v_requires_reason, v_direction
    from erp_ref.movement_type mt where mt.code = new.movement_type;

  if v_requires_reason and coalesce(new.reason_code, '') = '' then
    raise exception 'CLOVEERP_MOVEMENT_REASON_REQUIRED: % requires a reason code',
      new.movement_type using errcode = '23514',
      hint = 'Say why; the reason stays on the movement.';
  end if;

  -- A change of hands keeps the place and the condition and changes a party;
  -- anything else is an issue and a receipt, and says so.
  if new.movement_type in ('ownership_transfer', 'custody_transfer')
     and (new.from_location_id is distinct from new.to_location_id
          or new.from_status is distinct from new.to_status
          or (v_to_owner = new.owner_party_id and v_to_keeper = new.custody_party_id)) then
    raise exception 'CLOVEERP_TRANSFER_CHANGES_NOTHING: % must keep the place and condition and name another owner or keeper', new.movement_type
      using errcode = '23514',
            hint = 'erp.consume_consignment() and erp.hand_over_custody() write these movements; a move between places is an internal transfer.';
  end if;

  select * into v_item from erp.item i where i.id = new.item_id;

  if v_item.is_batch_controlled and new.batch_id is null then
    raise exception 'CLOVEERP_BATCH_REQUIRED: % is batch controlled', v_item.code
      using errcode = '23514', hint = 'Name the batch the stock belongs to.';
  end if;
  if not v_item.is_batch_controlled and new.batch_id is not null then
    raise exception 'CLOVEERP_BATCH_NOT_APPLICABLE: % is not batch controlled', v_item.code
      using errcode = '23514', hint = 'Leave the batch empty for an item that has none.';
  end if;
  if v_item.is_serial_controlled and new.serial_id is null then
    raise exception 'CLOVEERP_SERIAL_REQUIRED: % is serial controlled', v_item.code
      using errcode = '23514', hint = 'Name the serial number the stock carries.';
  end if;

  perform set_config('erp.ledger_write', 'on', true);

  if new.from_location_id is not null then
    insert into erp.stock_balance as b (
      tenant_id, site_id, location_id, item_id, batch_id, serial_id,
      container_id, owner_party_id, custody_party_id, stock_status, quantity)
    values (
      new.tenant_id, new.site_id, new.from_location_id, new.item_id, new.batch_id,
      new.serial_id, new.container_id, new.owner_party_id, new.custody_party_id,
      new.from_status, -new.quantity)
    on conflict (tenant_id, site_id, location_id, item_id,
                 coalesce(batch_id,     '00000000-0000-0000-0000-000000000000'::uuid),
                 coalesce(serial_id,    '00000000-0000-0000-0000-000000000000'::uuid),
                 coalesce(container_id, '00000000-0000-0000-0000-000000000000'::uuid),
                 owner_party_id, custody_party_id, stock_status)
      do update set quantity = b.quantity + excluded.quantity, updated_at = now()
    returning b.quantity into v_resulting;

    if v_resulting < 0 and not coalesce(v_allows_negative, false) then
      raise exception
        'CLOVEERP_NEGATIVE_STOCK: % would leave %.% at % in %',
        new.movement_type, v_item.code, coalesce(new.batch_id::text, ''),
        v_resulting, new.from_status
        using errcode = '23514',
              hint = 'Only movement types marked allows_negative may drive a position below zero. '
                     'A position is per owner and keeper: stock the company does not own cannot be issued as its own.';
    end if;
  end if;

  if new.to_location_id is not null then
    insert into erp.stock_balance as b (
      tenant_id, site_id, location_id, item_id, batch_id, serial_id,
      container_id, owner_party_id, custody_party_id, stock_status, quantity, first_received_at)
    values (
      new.tenant_id, new.site_id, new.to_location_id, new.item_id, new.batch_id,
      new.serial_id, new.container_id, v_to_owner, v_to_keeper,
      new.to_status, new.quantity, new.occurred_at)
    on conflict (tenant_id, site_id, location_id, item_id,
                 coalesce(batch_id,     '00000000-0000-0000-0000-000000000000'::uuid),
                 coalesce(serial_id,    '00000000-0000-0000-0000-000000000000'::uuid),
                 coalesce(container_id, '00000000-0000-0000-0000-000000000000'::uuid),
                 owner_party_id, custody_party_id, stock_status)
      do update set quantity = b.quantity + excluded.quantity,
                    -- A position that had emptied starts its clock again.
                    first_received_at = case when b.quantity <= 0 then excluded.first_received_at
                                             else coalesce(b.first_received_at, excluded.first_received_at) end,
                    updated_at = now();
  end if;

  perform set_config('erp.ledger_write', '', true);
  return new;
end;
$$;

-- The truth, aggregated: the to-side belongs to the to-side's parties.
create or replace view erp.stock_position with (security_invoker = true) as
with sides as (
  select m.tenant_id, m.site_id, m.to_location_id as location_id, m.item_id,
         m.batch_id, m.serial_id, m.container_id, m.to_status as stock_status,
         m.quantity as delta,
         coalesce(m.to_owner_party_id, m.owner_party_id) as owner_party_id,
         coalesce(m.to_custody_party_id, m.custody_party_id) as custody_party_id
    from erp.stock_movement m
   where m.to_location_id is not null
  union all
  select m.tenant_id, m.site_id, m.from_location_id, m.item_id,
         m.batch_id, m.serial_id, m.container_id, m.from_status,
         -m.quantity, m.owner_party_id, m.custody_party_id
    from erp.stock_movement m
   where m.from_location_id is not null
)
select tenant_id, site_id, location_id, item_id, batch_id, serial_id, container_id,
       stock_status, sum(delta) as quantity, owner_party_id, custody_party_id
  from sides
 group by tenant_id, site_id, location_id, item_id, batch_id, serial_id, container_id,
          stock_status, owner_party_id, custody_party_id
having sum(delta) <> 0;

comment on view erp.stock_position is
  'The stock ledger aggregated: quantity per site, location, item, batch, '
  'serial, container, status, owner and keeper; a movement that changes hands '
  'leaves the from-side''s parties and joins the to-side''s. Nothing writes it.';

-- The cost is the company''s when the company owns the stock after the movement.
do $stamp$
declare
  v_def text;
  v_n   text := E'  if new.owner_party_id <> v_company then\n    new.unit_cost_minor := null;\n    new.cost_minor := null;\n  end if;';
  v_r   text := E'  if coalesce(new.to_owner_party_id, new.owner_party_id) <> v_company then\n    new.unit_cost_minor := null;\n    new.cost_minor := null;\n  end if;';
begin
  v_def := pg_get_functiondef('erp.stamp_movement_parties()'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_STAMP_UNRECOGNISED: erp.stamp_movement_parties() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$stamp$;

-- A reversal of a change of hands changes them back.
do $reverse$
declare
  v_def text;
  v_n1  text := E'    correlation_id, reverses_movement_id, is_reversal, owner_party_id, custody_party_id)\n  values (';
  v_r1  text := E'    correlation_id, reverses_movement_id, is_reversal, owner_party_id, custody_party_id,\n    to_owner_party_id, to_custody_party_id)\n  values (';
  v_n2  text := E'    m.id, true, m.owner_party_id, m.custody_party_id)\n  returning id into v_new;';
  v_r2  text := E'    m.id, true, coalesce(m.to_owner_party_id, m.owner_party_id), coalesce(m.to_custody_party_id, m.custody_party_id),\n'
             || E'    case when m.to_owner_party_id is not null then m.owner_party_id end,\n'
             || E'    case when m.to_custody_party_id is not null then m.custody_party_id end)\n  returning id into v_new;';
begin
  v_def := pg_get_functiondef('erp.reverse_stock_movement(bigint,text)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1
     or (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1 then
    raise exception 'CLOVEERP_REVERSAL_UNRECOGNISED: erp.reverse_stock_movement() is not the body this migration patches';
  end if;
  execute replace(replace(v_def, v_n1, v_r1), v_n2, v_r2);
end
$reverse$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Consignment consumed is a purchase, and it posts
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values ('stock.ownership_transferred', 1, 'stock_movement', 'inventory', 'event.stock.ownership_transferred',
        'Stock changed owner where it stood; where the company became the owner its cost reaches the ledger.',
        '{"type":"object","required":["movement_id","cost_minor","reason_code"],
          "properties":{"movement_id":{"type":"integer"},"cost_minor":{"type":"integer"},
                        "reason_code":{"type":"string"},"movement_type":{"type":"string"},
                        "quantity":{"type":"number"}}}'::jsonb, true)
on conflict do nothing;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.stock.ownership_transferred', 'en', 'Stock changed owner', 'inventory',
   'Event raised when stock changes owner where it stands, such as consigned stock consumed.'),
  ('event.stock.ownership_transferred', 'de', 'Bestand hat den Eigentümer gewechselt', 'inventory',
   'Ereignis, wenn Bestand am Ort den Eigentümer wechselt, etwa verbrauchte Konsignationsware.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

-- The installer ships the rule (version 3); an installed organisation upgrades.
do $installer$
declare
  v_def text;
  v_n   text := E'''description'',''Stock adjustment''))))));';
  v_r   text := E'''description'',''Stock adjustment'')))),\n\n'
             || E'      jsonb_build_object(''kind'',''posting_rule'',''key'',''consignment_consumption'',''payload'',\n'
             || E'        jsonb_build_object(\n'
             || E'          ''code'',''consignment_consumption'',''name'',''Consignment consumed'',''ledger'',''GL'',\n'
             || E'          ''event_type'',''stock.ownership_transferred'',\n'
             || E'          ''posting_lines'', jsonb_build_array(\n'
             || E'            jsonb_build_object(''account'', erp.chart_account_code(''inventory''),''side'',''debit'',''basis'',''stock_cost'',''rate'',1,\n'
             || E'                               ''description'',''Consigned stock taken into ownership, at cost''),\n'
             || E'            jsonb_build_object(''account'', erp.chart_account_code(''goods_received_not_invoiced''),''side'',''credit'',''balancing'',true,\n'
             || E'                               ''description'',''Owed to the consignor''))))));';
begin
  v_def := pg_get_functiondef('erp.configure_inventory(erp.costing_method,text,numeric,numeric)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_INVENTORY_INSTALLER_UNRECOGNISED: erp.configure_inventory() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$installer$;

update erp_ref.module_installer
   set current_version = 3,
       description = 'Version 2 (20260906050000) added the stock adjustments account and the stock_adjustment posting rule; version 3 (20260906143000) the consignment_consumption rule, so consigned stock taken into ownership posts against goods received not invoiced.'
 where install_code = 'inventory-operations';

insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq) values
  ('inventory-operations', 3, 'posting_rule', 'consignment_consumption',
   jsonb_build_object(
     'code', 'consignment_consumption', 'name', 'Consignment consumed', 'ledger', 'GL',
     'event_type', 'stock.ownership_transferred',
     'posting_lines', jsonb_build_array(
       jsonb_build_object('account', jsonb_build_object('purpose', 'inventory'), 'side', 'debit', 'basis', 'stock_cost', 'rate', 1,
                          'description', 'Consigned stock taken into ownership, at cost'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'goods_received_not_invoiced'), 'side', 'credit', 'balancing', true,
                          'description', 'Owed to the consignor'))),
   110)
on conflict (install_code, to_version, object_kind, object_key) do update set payload = excluded.payload, seq = excluded.seq;

-- The movement's posting reads the rule its event names.
do $finance$
declare
  v_def text;
  v_n1  text := E'  v_in      boolean;\nbegin';
  v_r1  text := E'  v_in      boolean;\n  v_event_type text;\nbegin';
  v_n2  text := E'  v_in := m.to_location_id is not null and m.from_location_id is null;';
  v_r2  text := E'  v_in := (m.to_location_id is not null and m.from_location_id is null) or m.movement_type = ''ownership_transfer'';\n'
             || E'  v_event_type := case when m.movement_type = ''ownership_transfer'' then ''stock.ownership_transferred'' else ''stock.adjusted'' end;';
  v_n3  text := E'   where r.tenant_id = v_tenant and r.event_type = ''stock.adjusted'' and r.status = ''active''';
  v_r3  text := E'   where r.tenant_id = v_tenant and r.event_type = v_event_type and r.status = ''active''';
  v_n4  text := E'    raise exception ''CLOVEERP_NO_POSTING_RULE_IN_FORCE: no stock_adjustment posting rule is in force for this organisation''\n'
             || E'      using errcode = ''23514'',\n'
             || E'            hint = ''The inventory installer ships the stock_adjustment rule from 20260906050000; an organisation configured before it promotes a change set carrying the rule.'';';
  v_r4  text := E'    raise exception ''CLOVEERP_NO_POSTING_RULE_IN_FORCE: no posting rule for % is in force for this organisation'', v_event_type\n'
             || E'      using errcode = ''23514'',\n'
             || E'            hint = ''erp_upgrade_module_configuration(''''inventory-operations'''') delivers the rules the inventory installer ships.'';';
  v_n5  text := E'  v_event := erp.append_event(''stock.adjusted'', ''stock_movement'', m.movement_uid,';
  v_r5  text := E'  v_event := erp.append_event(v_event_type, ''stock_movement'', m.movement_uid,';
  v_n6  text := E'  values (v_tenant, m.entity_id, v_ledger, ''stock.adjusted'', v_event,';
  v_r6  text := E'  values (v_tenant, m.entity_id, v_ledger, v_event_type, v_event,';
begin
  v_def := pg_get_functiondef('erp.post_movement_finance(bigint)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1
     or (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1
     or (length(v_def) - length(replace(v_def, v_n3, ''))) / length(v_n3) <> 1
     or (length(v_def) - length(replace(v_def, v_n4, ''))) / length(v_n4) <> 1
     or (length(v_def) - length(replace(v_def, v_n5, ''))) / length(v_n5) <> 1
     or (length(v_def) - length(replace(v_def, v_n6, ''))) / length(v_n6) <> 1 then
    raise exception 'CLOVEERP_MOVEMENT_POSTING_UNRECOGNISED: erp.post_movement_finance() is not the body this migration patches';
  end if;
  execute replace(replace(replace(replace(replace(replace(v_def, v_n1, v_r1), v_n2, v_r2), v_n3, v_r3), v_n4, v_r4), v_n5, v_r5), v_n6, v_r6);
end
$finance$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A write-off knows whose stock it writes off
-- ═════════════════════════════════════════════════════════════════════════════

do $check$
declare v_def text := pg_get_functiondef('erp.write_off_stock(uuid,uuid,uuid,numeric,text,uuid)'::regprocedure);
begin
  if position(E'  v_cost := erp.issue_cost(p_item_id, p_site_id, p_quantity);' in v_def) = 0
     or position(E'  perform erp.post_movement_finance(v_id);' in v_def) = 0 then
    raise exception 'CLOVEERP_WRITE_OFF_UNRECOGNISED: erp.write_off_stock() is not the body this migration restates';
  end if;
end
$check$;

-- One name, one function: the six-argument form goes before the seven-argument
-- form arrives, so the device handler and the door cannot find two.
drop function erp.write_off_stock(uuid, uuid, uuid, numeric, text, uuid);

create function erp.write_off_stock(
  p_item_id  uuid,
  p_site_id  uuid,
  p_location_id uuid,
  p_quantity numeric,
  p_reason   text,
  p_batch_id uuid default null,
  p_owner_party_id uuid default null
) returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_company uuid;
  v_owner   uuid;
  v_cost    bigint;
  v_uom     uuid;
  v_id      bigint;
begin
  if coalesce(p_reason, '') = '' then
    raise exception
      'CLOVEERP_WRITE_OFF_NEEDS_REASON: stock is not written off without one'
      using errcode = '23514',
            hint = 'Say why the stock is lost; the reason is kept on the movement.';
  end if;

  perform erp.authorise('inventory.write_off', null, p_site_id, null,
                        'item', p_item_id);

  select i.stock_uom_id into v_uom from erp.item i
   where i.tenant_id = v_tenant and i.id = p_item_id;

  v_company := erp.entity_party_for_site(p_site_id);
  v_owner   := coalesce(p_owner_party_id, v_company);

  -- Consuming cost layers, so a write-off relieves inventory at what the stock
  -- cost rather than at nothing — and only when the stock is the company's:
  -- a supplier's consigned position carries no cost on these books.
  v_cost := case when v_owner = v_company
                 then erp.issue_cost(p_item_id, p_site_id, p_quantity) end;

  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
    from_location_id, from_status, quantity, uom_id, unit_cost_minor, currency,
    reason_code, owner_party_id)
  select v_tenant, s.entity_id, p_site_id, 'scrap', p_item_id, p_batch_id,
         p_location_id, 'available', p_quantity, v_uom, v_cost,
         coalesce((select e.base_currency from erp.entity e
                    where e.tenant_id = v_tenant limit 1), 'GBP'),
         left(p_reason, 64), v_owner
    from erp.site s where s.id = p_site_id
  returning id into v_id;

  perform erp.post_movement_finance(v_id);

  return v_id;
end;
$$;

comment on function erp.write_off_stock(uuid, uuid, uuid, numeric, text, uuid, uuid) is
  'Writes stock off with its reason. The owner defaults to the company; a '
  'supplier''s consigned position is written off as the supplier''s, with no '
  'cost and no journal. Costed at what the stock cost, and posted.';

drop function if exists public.erp_write_off_stock(uuid, uuid, uuid, numeric, text, uuid);
create function public.erp_write_off_stock(
  p_item_id uuid, p_site_id uuid, p_location_id uuid, p_quantity numeric, p_reason text,
  p_batch_id uuid default null, p_owner_party_id uuid default null)
returns bigint
language sql
volatile
security invoker
set search_path = ''
as $$
  select erp.write_off_stock(p_item_id, p_site_id, p_location_id, p_quantity, p_reason, p_batch_id, p_owner_party_id)
$$;

revoke all on function public.erp_write_off_stock(uuid, uuid, uuid, numeric, text, uuid, uuid) from public, anon;
grant execute on function public.erp_write_off_stock(uuid, uuid, uuid, numeric, text, uuid, uuid) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_write_off_stock', 'erp.write_off_stock',
   'Writes stock off under inventory.write_off, which is its own permission because a write-off is a loss rather than an adjustment; the owner may be named so a consigned position is written off as the supplier''s.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

update erp_ref.part5_capability
   set artefacts = array_replace(artefacts, 'erp.write_off_stock(uuid,uuid,uuid,numeric,text,uuid)',
                                            'erp.write_off_stock(uuid,uuid,uuid,numeric,text,uuid,uuid)')
 where 'erp.write_off_stock(uuid,uuid,uuid,numeric,text,uuid)' = any (artefacts);

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Consigned stock is consumed, and stock is handed to a keeper
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.consume_consignment(
  p_item_id uuid, p_site_id uuid, p_location_id uuid, p_quantity numeric,
  p_supplier_party_id uuid, p_batch_id uuid default null, p_reason text default 'consumed')
returns bigint
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_entity  uuid;
  v_company uuid;
  v_held    numeric;
  v_price   bigint;
  v_ccy     char(3);
  v_unit    bigint;
  v_uom     uuid;
  v_id      bigint;
begin
  select s.entity_id into v_entity from erp.site s where s.tenant_id = v_tenant and s.id = p_site_id;
  if v_entity is null then
    raise exception 'CLOVEERP_UNKNOWN_SITE: % is not a site of this organisation', p_site_id
      using errcode = '23503', hint = 'erp_sites() lists the sites.';
  end if;
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'CLOVEERP_QUANTITY_NONPOSITIVE: nothing is consumed by %', p_quantity
      using errcode = '23514', hint = 'Consume a positive quantity.';
  end if;

  perform erp.authorise('inventory.adjust', v_entity, p_site_id, null, 'item', p_item_id);

  v_company := erp.entity_party_for_site(p_site_id);
  if p_supplier_party_id = v_company then
    raise exception 'CLOVEERP_NOT_CONSIGNED_HERE: the company already owns its own stock'
      using errcode = '23514', hint = 'Name the supplier who owns the consigned position.';
  end if;

  select coalesce(sum(b.quantity), 0) into v_held
    from erp.stock_balance b
   where b.tenant_id = v_tenant and b.site_id = p_site_id and b.location_id = p_location_id
     and b.item_id = p_item_id and b.batch_id is not distinct from p_batch_id
     and b.owner_party_id = p_supplier_party_id and b.custody_party_id = v_company
     and b.stock_status = 'available';
  if v_held < p_quantity then
    raise exception 'CLOVEERP_NOT_CONSIGNED_HERE: the supplier owns % of this item here and % was asked for', v_held, p_quantity
      using errcode = '23514',
            hint = 'erp_stock_position() shows the positions by owner; consume what the supplier''s position holds at this location.';
  end if;

  -- The price the consignor will invoice: the receipt that brought the stock
  -- in, else the supplier''s catalogue.
  select l.unit_price_minor, coalesce(l.currency, d.currency) into v_price, v_ccy
    from erp.document d
    join erp.document_line l on l.tenant_id = d.tenant_id and l.document_id = d.id
   where d.tenant_id = v_tenant and d.stock_owner_party_id = p_supplier_party_id
     and l.item_id = p_item_id and (p_batch_id is null or l.batch_id = p_batch_id)
     and coalesce(l.unit_price_minor, 0) > 0
   order by d.document_date desc, l.line_no desc limit 1;
  if v_price is null then
    select rp.amount_minor, rp.currency into v_price, v_ccy
      from erp.resolve_purchase_price(p_item_id, p_supplier_party_id, p_quantity, current_date, p_site_id) rp;
  end if;
  if v_price is null then
    raise exception 'CLOVEERP_CONSIGNMENT_PRICE_UNKNOWN: nothing says what the supplier charges for this item'
      using errcode = '23514',
            hint = 'Receive the stock against a priced consignment order, or load a purchase price for the supplier; the consumption posts at that price.';
  end if;

  select i.stock_uom_id into v_uom from erp.item i where i.id = p_item_id;

  -- The company receives the stock into its books at the consigned price.
  v_unit := erp.receive_cost(p_item_id, p_site_id, p_quantity, v_price, v_ccy, p_batch_id, null);

  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
    from_location_id, from_status, to_location_id, to_status,
    quantity, uom_id, unit_cost_minor, currency, reason_code,
    owner_party_id, custody_party_id, to_owner_party_id)
  values (v_tenant, v_entity, p_site_id, 'ownership_transfer', p_item_id, p_batch_id,
          p_location_id, 'available', p_location_id, 'available',
          p_quantity, v_uom, v_unit, v_ccy, left(coalesce(p_reason, 'consumed'), 64),
          p_supplier_party_id, v_company, v_company)
  returning id into v_id;

  perform erp.post_movement_finance(v_id);
  return v_id;
end;
$$;

revoke all on function erp.consume_consignment(uuid, uuid, uuid, numeric, uuid, uuid, text) from public, anon;

comment on function erp.consume_consignment(uuid, uuid, uuid, numeric, uuid, uuid, text) is
  'Consigned stock taken into the company''s ownership where it stands: the '
  'supplier''s position becomes the company''s at the consigned price, costed '
  'as a receipt, and posted — inventory against goods received not invoiced — '
  'because the supplier will invoice what was used.';

create or replace function erp.hand_over_custody(
  p_item_id uuid, p_site_id uuid, p_location_id uuid, p_quantity numeric,
  p_keeper_party_id uuid, p_batch_id uuid default null, p_reason text default 'handed over')
returns bigint
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_entity  uuid;
  v_keeper  uuid;
  v_owner   uuid;
  v_held    numeric;
  v_uom     uuid;
  v_id      bigint;
begin
  select s.entity_id into v_entity from erp.site s where s.tenant_id = v_tenant and s.id = p_site_id;
  if v_entity is null then
    raise exception 'CLOVEERP_UNKNOWN_SITE: % is not a site of this organisation', p_site_id
      using errcode = '23503', hint = 'erp_sites() lists the sites.';
  end if;
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'CLOVEERP_QUANTITY_NONPOSITIVE: nothing is handed over by %', p_quantity
      using errcode = '23514', hint = 'Hand over a positive quantity.';
  end if;
  if not exists (select 1 from erp.party p where p.tenant_id = v_tenant and p.id = p_keeper_party_id and p.status = 'active') then
    raise exception 'CLOVEERP_UNKNOWN_PARTY: % is not an active party of this organisation', p_keeper_party_id
      using errcode = '23503', hint = 'The keeper is a party: a provider, a contract manufacturer, the company itself.';
  end if;

  perform erp.authorise('inventory.adjust', v_entity, p_site_id, null, 'item', p_item_id);

  v_keeper := erp.entity_party_for_site(p_site_id);
  if v_keeper = p_keeper_party_id then
    raise exception 'CLOVEERP_TRANSFER_CHANGES_NOTHING: the stock is already kept by that party'
      using errcode = '23514', hint = 'Name the party that takes the stock into its keeping.';
  end if;

  -- One owner's position the company keeps today: its own first, else the
  -- one owner whose position covers the quantity. A hand-over never mixes owners.
  select b.owner_party_id, sum(b.quantity) into v_owner, v_held
    from erp.stock_balance b
   where b.tenant_id = v_tenant and b.site_id = p_site_id and b.location_id = p_location_id
     and b.item_id = p_item_id and b.batch_id is not distinct from p_batch_id
     and b.custody_party_id = v_keeper
     and b.stock_status = 'available' and b.quantity > 0
   group by b.owner_party_id
  having sum(b.quantity) >= p_quantity
   order by (b.owner_party_id = v_keeper) desc, sum(b.quantity) desc
   limit 1;
  if v_owner is null then
    select coalesce(sum(b.quantity), 0) into v_held
      from erp.stock_balance b
     where b.tenant_id = v_tenant and b.site_id = p_site_id and b.location_id = p_location_id
       and b.item_id = p_item_id and b.batch_id is not distinct from p_batch_id
       and b.custody_party_id = v_keeper and b.stock_status = 'available' and b.quantity > 0;
    raise exception 'CLOVEERP_NOT_HELD_HERE: no one owner''s position the company keeps here covers %; the company keeps % in all', p_quantity, v_held
      using errcode = '23514',
            hint = 'erp_stock_position() shows the positions by owner and keeper; hand over what one owner''s position holds at this location.';
  end if;

  select i.stock_uom_id into v_uom from erp.item i where i.id = p_item_id;

  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
    from_location_id, from_status, to_location_id, to_status,
    quantity, uom_id, reason_code,
    owner_party_id, custody_party_id, to_custody_party_id)
  values (v_tenant, v_entity, p_site_id, 'custody_transfer', p_item_id, p_batch_id,
          p_location_id, 'available', p_location_id, 'available',
          p_quantity, v_uom, left(coalesce(p_reason, 'handed over'), 64),
          v_owner, v_keeper, p_keeper_party_id)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function erp.hand_over_custody(uuid, uuid, uuid, numeric, uuid, uuid, text) from public, anon;

comment on function erp.hand_over_custody(uuid, uuid, uuid, numeric, uuid, uuid, text) is
  'Stock the company keeps is handed to another keeper where it stands; the '
  'owner and the valuation do not move, and the count follows the keeper.';

create or replace function public.erp_consume_consignment(
  p_item_id uuid, p_site_id uuid, p_location_id uuid, p_quantity numeric,
  p_supplier_party_id uuid, p_batch_id uuid default null, p_reason text default 'consumed')
returns bigint
language sql
set search_path = ''
as $$
  select erp.consume_consignment(p_item_id, p_site_id, p_location_id, p_quantity, p_supplier_party_id, p_batch_id, p_reason)
$$;

create or replace function public.erp_hand_over_custody(
  p_item_id uuid, p_site_id uuid, p_location_id uuid, p_quantity numeric,
  p_keeper_party_id uuid, p_batch_id uuid default null, p_reason text default 'handed over')
returns bigint
language sql
set search_path = ''
as $$
  select erp.hand_over_custody(p_item_id, p_site_id, p_location_id, p_quantity, p_keeper_party_id, p_batch_id, p_reason)
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. A policy is proposed by class and by site
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.propose_identity_policy(
  p_code text, p_name text, p_item_class text, p_site_code text, p_device_task_code text,
  p_identity_level text, p_count_method text, p_effective_from date, p_change_set_id uuid)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('administration.configure', null, null, null, 'change_set', p_change_set_id);

  if not exists (select 1 from erp_ref.container_type ct where ct.code = p_identity_level) then
    raise exception 'CLOVEERP_UNKNOWN_IDENTITY_LEVEL: % is not a level a handling unit carries', p_identity_level
      using errcode = '23503', hint = 'none, unit, case, carton, pallet or master_pallet.';
  end if;
  if p_count_method not in ('by_unit', 'by_container', 'hybrid') then
    raise exception 'CLOVEERP_UNKNOWN_COUNT_METHOD: % is not a way to count', p_count_method
      using errcode = '23514', hint = 'by_unit, by_container or hybrid.';
  end if;
  if p_count_method <> 'by_unit' and p_identity_level = 'none' then
    raise exception 'CLOVEERP_COUNT_NEEDS_AN_IDENTITY: counting by container needs a level a container carries'
      using errcode = '23514', hint = 'Choose a level above none, or count by unit.';
  end if;
  if p_site_code is not null and not exists (select 1 from erp.site s where s.tenant_id = v_tenant and s.code = p_site_code) then
    raise exception 'CLOVEERP_UNKNOWN_SITE: % is not a site of this organisation', p_site_code
      using errcode = '23503', hint = 'erp_sites() lists the sites by code.';
  end if;
  if p_device_task_code is not null and not exists (select 1 from erp_ref.device_task t where t.code = p_device_task_code) then
    raise exception 'CLOVEERP_UNKNOWN_DEVICE_TASK: % is not a step a device performs', p_device_task_code
      using errcode = '23503', hint = 'erp_vocabularies() lists the device tasks.';
  end if;

  return erp.add_change_set_item(p_change_set_id, 'container_identity_policy', p_code,
    jsonb_strip_nulls(jsonb_build_object(
      'code', p_code, 'name', coalesce(p_name, p_code),
      'item_class', p_item_class, 'site', p_site_code, 'device_task', p_device_task_code,
      'identity_level', p_identity_level, 'count_method', p_count_method,
      'effective_from', coalesce(p_effective_from, current_date))),
    'upsert', null, 'proposed from the stock policies screen');
end;
$$;

revoke all on function erp.propose_identity_policy(text, text, text, text, text, text, text, date, uuid) from public, anon;

comment on function erp.propose_identity_policy(text, text, text, text, text, text, text, date, uuid) is
  'Proposes a handling-unit identity policy — for a product class, a site, a '
  'device step, or any of them — as an item of a change set, which promotion '
  'writes. The policy resolver already prefers site over class over step.';

create or replace function erp.propose_allocation_policy(
  p_entity_code text, p_site_code text, p_value jsonb, p_change_set_id uuid)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity text := p_entity_code;
  ct       erp_ref.config_type%rowtype;
begin
  perform erp.authorise('administration.configure', null, null, null, 'change_set', p_change_set_id);

  select * into ct from erp_ref.config_type c where c.code = 'stock.allocation_policy';
  if not erp.jsonb_matches_schema(ct.value_schema::json, coalesce(p_value, '{}'::jsonb)) then
    raise exception 'CLOVEERP_POLICY_VALUE_INVALID: the allocation policy does not fit its declared shape'
      using errcode = '22023',
            hint = 'expiry_controlled and default name fefo, fifo or lifo; single_batch_per_order and prefer_nearest_location are yes or no.';
  end if;
  if p_site_code is not null then
    select e.code into v_entity
      from erp.site s join erp.entity e on e.id = s.entity_id
     where s.tenant_id = v_tenant and s.code = p_site_code;
    if v_entity is null then
      raise exception 'CLOVEERP_UNKNOWN_SITE: % is not a site of this organisation', p_site_code
        using errcode = '23503', hint = 'erp_sites() lists the sites by code; a site policy belongs to the site''s company.';
    end if;
  elsif p_entity_code is not null and not exists (select 1 from erp.entity e where e.tenant_id = v_tenant and e.code = p_entity_code) then
    raise exception 'CLOVEERP_UNKNOWN_ENTITY: % is not a company of this organisation', p_entity_code
      using errcode = '23503', hint = 'erp_entities() lists the companies by code.';
  end if;

  return erp.add_change_set_item(p_change_set_id, 'config',
    format('stock.allocation_policy|%s|%s', coalesce(v_entity, '*'), coalesce(p_site_code, '*')),
    jsonb_strip_nulls(jsonb_build_object(
      'config_type', 'stock.allocation_policy', 'value', p_value,
      'entity', v_entity, 'site', p_site_code)),
    'upsert', null, 'proposed from the stock policies screen');
end;
$$;

revoke all on function erp.propose_allocation_policy(text, text, jsonb, uuid) from public, anon;

comment on function erp.propose_allocation_policy(text, text, jsonb, uuid) is
  'Proposes how a company or a site chooses stock for an order, as an item of '
  'a change set. A value scopes to a company or a site; the class dimension is '
  'the policy''s own keys (expiry-controlled stock and the rest).';

create or replace function erp.container_identity_policies()
returns table (code text, name text, item_class text, site text, device_task text,
               identity_level text, count_method text, effective_from date, status text)
language sql
stable
set search_path = ''
as $$
  select p.code, p.name, p.item_class, s.code, p.device_task_code,
         p.identity_level, p.count_method, p.effective_from, p.status::text
    from erp.container_identity_policy p
    left join erp.site s on s.id = p.site_id
   where p.tenant_id = erp.current_tenant_id()
   order by p.status, p.code
$$;

revoke all on function erp.container_identity_policies() from public, anon;

create or replace function public.erp_container_identity_policies()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(p) order by p.status, p.code), '[]'::jsonb)
    from erp.container_identity_policies() p
$$;

create or replace function public.erp_propose_identity_policy(
  p_code text, p_name text, p_item_class text, p_site_code text, p_device_task_code text,
  p_identity_level text, p_count_method text, p_effective_from date, p_change_set_id uuid)
returns uuid
language sql
set search_path = ''
as $$
  select erp.propose_identity_policy(p_code, p_name, p_item_class, p_site_code, p_device_task_code,
                                     p_identity_level, p_count_method, p_effective_from, p_change_set_id)
$$;

create or replace function public.erp_propose_allocation_policy(
  p_entity_code text, p_site_code text, p_value jsonb, p_change_set_id uuid)
returns uuid
language sql
set search_path = ''
as $$
  select erp.propose_allocation_policy(p_entity_code, p_site_code, p_value, p_change_set_id)
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'erp_consume_consignment(uuid, uuid, uuid, numeric, uuid, uuid, text)',
    'erp_hand_over_custody(uuid, uuid, uuid, numeric, uuid, uuid, text)',
    'erp_container_identity_policies()',
    'erp_propose_identity_policy(text, text, text, text, text, text, text, date, uuid)',
    'erp_propose_allocation_policy(text, text, jsonb, uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_consume_consignment', 'erp.consume_consignment',
   'Takes consigned stock into the company''s ownership where it stands, at the consigned price, and posts it; authorises inventory.adjust.'),
  ('erp_hand_over_custody', 'erp.hand_over_custody',
   'Hands stock the company keeps to another keeper where it stands; authorises inventory.adjust.'),
  ('erp_propose_identity_policy', 'erp.propose_identity_policy',
   'Proposes a handling-unit identity policy by class, site or step as a change-set item; authorises administration.configure.'),
  ('erp_propose_allocation_policy', 'erp.propose_allocation_policy',
   'Proposes how a company or a site chooses stock as a change-set item; authorises administration.configure.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/inventory',
  array['erp_consume_consignment', 'erp_hand_over_custody', 'erp_container_identity_policies',
        'erp_propose_identity_policy', 'erp_propose_allocation_policy']);

-- ── The interview asks ──────────────────────────────────────────────────────

insert into erp_ref.interview_question
  (code, section, surface, seq, prompt, prompt_key, help, answer_shape, choices, maps_to, applies_when, is_required) values
  ('org.policies_differ', 'B.7', 'container_identity_policy', 81,
   'Does handling-unit identity or the way stock is chosen differ by product class or by site?',
   'interview.org.policies_differ',
   'Most organisations answer no. A cold store that picks by expiry while the rest picks first-in, or finished goods on pallets while raw materials are loose, answers yes.',
   'boolean', null, null, null, false),
  ('org.identity_by_class', 'B.7', 'container_identity_policy', 82,
   'Which product classes carry a different handling-unit identity, and at what level?',
   'interview.org.identity_by_class',
   'One pair per class: the class code and the level (none, unit, case, carton, pallet, master_pallet).',
   'text_pairs', null, 'container_identity_policy', 'org.policies_differ', false),
  ('org.allocation_by_site', 'B.7', 'config', 83,
   'Which sites choose stock differently, and how?',
   'interview.org.allocation_by_site',
   'One pair per site: the site code and the method for stock without an expiry (fifo or lifo); stock with an expiry is always first-expiring first.',
   'text_pairs', null, 'config', 'org.policies_differ', false)
on conflict (code) do update
  set section = excluded.section, surface = excluded.surface, seq = excluded.seq, prompt = excluded.prompt,
      prompt_key = excluded.prompt_key, help = excluded.help, answer_shape = excluded.answer_shape,
      choices = excluded.choices, maps_to = excluded.maps_to, applies_when = excluded.applies_when,
      is_required = excluded.is_required;

-- The shape proposer emits one scoped item per pair.
do $shape$
declare
  v_def text;
  v_n   text := E'  return v_items;\nend;';
  v_r   text := E'  -- Policies that differ by product class or by site: one scoped item per pair.\n'
             || E'  for v_pair in\n'
             || E'    select e.value from erp.interview_answer ia\n'
             || E'    cross join lateral jsonb_array_elements(case when jsonb_typeof(ia.answer) = ''array'' then ia.answer else ''[]''::jsonb end) e\n'
             || E'     where ia.tenant_id = v_tenant and ia.session_id = p_session_id and ia.question_code = ''org.identity_by_class''\n'
             || E'  loop\n'
             || E'    v_k := upper(btrim(coalesce(v_pair ->> 0, v_pair ->> ''class'', v_pair ->> ''key'')));\n'
             || E'    v_v := lower(btrim(coalesce(v_pair ->> 1, v_pair ->> ''level'', v_pair ->> ''value'')));\n'
             || E'    continue when coalesce(v_k, '''') = '''' or v_v not in (''none'', ''unit'', ''case'', ''carton'', ''pallet'', ''master_pallet'');\n'
             || E'    perform erp.add_change_set_item(p_change_set_id, ''container_identity_policy'', ''CLASS-'' || v_k,\n'
             || E'      jsonb_build_object(''code'', ''CLASS-'' || v_k, ''name'', ''Identity for '' || v_k, ''item_class'', v_k,\n'
             || E'                         ''identity_level'', v_v,\n'
             || E'                         ''count_method'', case when v_v in (''none'', ''unit'') then ''by_unit'' else ''hybrid'' end));\n'
             || E'    v_items := v_items + 1;\n'
             || E'  end loop;\n'
             || E'  for v_pair in\n'
             || E'    select e.value from erp.interview_answer ia\n'
             || E'    cross join lateral jsonb_array_elements(case when jsonb_typeof(ia.answer) = ''array'' then ia.answer else ''[]''::jsonb end) e\n'
             || E'     where ia.tenant_id = v_tenant and ia.session_id = p_session_id and ia.question_code = ''org.allocation_by_site''\n'
             || E'  loop\n'
             || E'    v_k := upper(btrim(coalesce(v_pair ->> 0, v_pair ->> ''site'', v_pair ->> ''key'')));\n'
             || E'    v_v := lower(btrim(coalesce(v_pair ->> 1, v_pair ->> ''method'', v_pair ->> ''value'')));\n'
             || E'    continue when coalesce(v_k, '''') = '''' or v_v not in (''fefo'', ''fifo'', ''lifo'');\n'
             || E'    perform erp.add_change_set_item(p_change_set_id, ''config'', ''stock.allocation_policy|*|'' || v_k,\n'
             || E'      jsonb_build_object(''config_type'', ''stock.allocation_policy'', ''site'', v_k,\n'
             || E'                         ''entity'', (select e2.code from erp.site s2 join erp.entity e2 on e2.id = s2.entity_id\n'
             || E'                                       where s2.tenant_id = v_tenant and s2.code = v_k),\n'
             || E'                         ''value'', jsonb_build_object(''expiry_controlled'', ''fefo'', ''default'', v_v,\n'
             || E'                                                     ''single_batch_per_order'', false, ''prefer_nearest_location'', true)));\n'
             || E'    v_items := v_items + 1;\n'
             || E'  end loop;\n\n'
             || E'  return v_items;\nend;';
  v_n2  text := E'declare\n';
  v_r2  text := E'declare\n  v_pair jsonb; v_k text; v_v text;\n';
begin
  v_def := pg_get_functiondef('erp.propose_organisation_shape(uuid,uuid)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1
     or (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1 then
    raise exception 'CLOVEERP_SHAPE_PROPOSER_UNRECOGNISED: erp.propose_organisation_shape() is not the body this migration patches';
  end if;
  execute replace(replace(v_def, v_n, v_r), v_n2, v_r2);
end
$shape$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The registers
-- ═════════════════════════════════════════════════════════════════════════════

update erp_ref.part5_capability
   set artefacts = artefacts || array['erp.consume_consignment(uuid,uuid,uuid,numeric,uuid,uuid,text)',
                                      'erp.hand_over_custody(uuid,uuid,uuid,numeric,uuid,uuid,text)']
 where code = '5.3.order_types'
   and not ('erp.consume_consignment(uuid,uuid,uuid,numeric,uuid,uuid,text)' = any (artefacts));

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.consignment_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid; v_admin uuid; v_token text;
  v_entity uuid; v_site uuid; v_ccy char(3); v_company uuid; v_supplier uuid; v_recv uuid; v_3pl uuid;
  v_item uuid; v_grn uuid; v_move bigint; v_hand bigint;
  v_sup_q numeric; v_co_q numeric; v_val bigint; v_val2 bigint; v_n integer; v_j integer;
  v_ok boolean; v_msg text; v_keeper uuid; v_owner uuid;
begin
  begin
    select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
      from erp.provision_tenant('zzcons', 'Consignment suite', 'admin@zzcons.test', 'Consignment Admin') t;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000f3', 'admin@zzcons.test');
    perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000f3')::text, true);
    perform erp.claim_invitation(v_token);
    perform erp.ensure_demo_configuration(v_tenant, v_admin);

    select e.id, e.base_currency, e.party_id into v_entity, v_ccy, v_company from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
    select s.id into v_site from erp.site s where s.tenant_id = v_tenant and s.site_type = 'warehouse' order by s.code limit 1;
    select l.id into v_recv from erp.location l where l.tenant_id = v_tenant and l.site_id = v_site and l.location_type = 'receiving' limit 1;
    select pr.party_id into v_supplier from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'supplier' order by pr.party_id limit 1;
    insert into erp.party (tenant_id, code, name, status) values (v_tenant, 'ZZ-3PL', 'A provider', 'active') returning id into v_3pl;
    insert into erp.item (tenant_id, code, name, item_class, stock_uom_id, status)
    select v_tenant, 'ZZ-CONS', 'Consigned item', 'RAW', u.id, 'active' from erp.uom u where u.tenant_id = v_tenant and u.is_base limit 1
    returning id into v_item;

    -- Five, consigned: owned by the supplier, kept by the company, off the books.
    v_grn := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'ZZ-GRN-CONS', '{}'::jsonb);
    update erp.document set stock_owner_party_id = v_supplier where id = v_grn;
    perform erp.add_document_line(v_grn, v_item, 5, 900, 'consigned', current_date);
    perform erp.transition_document(v_grn, 'post', 'consignment suite');
    set constraints all immediate;
    select coalesce(sum(v.value_minor), 0) into v_val from erp.stock_valuation_report() v where v.item_id = v_item;

    -- 1. Three are consumed where they stand.
    v_move := erp.consume_consignment(v_item, v_site, v_recv, 3, v_supplier, null, 'used in production');
    set constraints all immediate;
    select coalesce(sum(b.quantity), 0) into v_sup_q from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_item and b.owner_party_id = v_supplier;
    select coalesce(sum(b.quantity), 0) into v_co_q from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_item and b.owner_party_id = v_company;
    return query select 'consumed consigned stock changes owner where it stands and the positions agree with the ledger',
      v_sup_q = 2 and v_co_q = 3
      and (select coalesce(sum(p.quantity), 0) from erp.stock_position p where p.tenant_id = v_tenant and p.item_id = v_item and p.owner_party_id = v_company) = 3
      and not exists (select 1 from erp.stock_reconciliation_report())
      and not exists (select 1 from erp.ownership_report()),
      format('supplier %s (expected 2), company %s (expected 3); stock and ownership reconcile', v_sup_q, v_co_q);

    -- 2. The movement says what it did and what it cost.
    return query select 'the movement names both owners and carries the consigned price',
      exists (select 1 from erp.stock_movement m where m.id = v_move and m.movement_type = 'ownership_transfer'
               and m.owner_party_id = v_supplier and m.to_owner_party_id = v_company
               and m.unit_cost_minor = 900 and m.cost_minor = 2700 and m.from_location_id = m.to_location_id),
      'ownership_transfer, supplier → company, 900 a unit, 2700 in all';

    -- 3. And it posts: inventory against goods received not invoiced.
    select count(*) into v_j from erp.journal j where j.tenant_id = v_tenant and j.source_code = 'stock.ownership_transferred' and j.status = 'posted';
    select coalesce(sum(v.value_minor), 0) into v_val2 from erp.stock_valuation_report() v where v.item_id = v_item;
    select count(*) filter (where r.difference_minor <> 0) into v_n from erp.inventory_reconciliation_report() r;
    return query select 'the consumption posts inventory against goods received not invoiced and the valuation moves with it',
      v_j = 1 and v_val2 - v_val = 2700 and v_n = 0
      and exists (select 1 from erp.journal j join erp.journal_line l on l.journal_id = j.id join erp.account a on a.id = l.account_id
                   where j.tenant_id = v_tenant and j.source_code = 'stock.ownership_transferred'
                     and a.code = erp.chart_account_code('goods_received_not_invoiced') and l.credit_minor = 2700),
      format('%s journal(s), valuation up by %s (expected 2700), %s account(s) out of balance', v_j, v_val2 - v_val, v_n);

    -- 4. More than the supplier owns here is refused.
    v_ok := false; v_msg := null;
    begin
      perform erp.consume_consignment(v_item, v_site, v_recv, 10, v_supplier, null, 'too many');
      v_msg := 'it consumed';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_NOT_CONSIGNED_HERE%'; v_msg := left(sqlerrm, 100);
    end;
    return query select 'consuming more than the supplier owns here is refused by name', v_ok, v_msg;

    -- 5. Custody handed to a provider: the keeper moves, nothing else does.
    select count(*) into v_j from erp.journal j where j.tenant_id = v_tenant and j.source_code like 'stock.%';
    v_hand := erp.hand_over_custody(v_item, v_site, v_recv, 2, v_3pl, null, 'to the provider');
    set constraints all immediate;
    select b.owner_party_id, b.custody_party_id into v_owner, v_keeper
      from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_item and b.custody_party_id = v_3pl and b.quantity > 0;
    select coalesce(sum(v.value_minor), 0) into v_val from erp.stock_valuation_report() v where v.item_id = v_item;
    return query select 'handing stock to a provider changes the keeper and neither the owner nor the valuation',
      v_keeper = v_3pl and v_owner = v_company and v_val = v_val2
      and (select coalesce(sum(b.quantity), 0) from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_item and b.custody_party_id = v_company and b.owner_party_id = v_company) = 1
      and (select count(*) from erp.journal j where j.tenant_id = v_tenant and j.source_code like 'stock.%') = v_j,
      format('keeper is the provider: %s, owner still the company: %s, valuation %s (unchanged)', v_keeper = v_3pl, v_owner = v_company, v_val);

    -- 6. A supplier's position is written off as the supplier's.
    select count(*) into v_j from erp.journal j where j.tenant_id = v_tenant and j.source_code = 'stock.adjusted';
    perform erp.write_off_stock(v_item, v_site, v_recv, 1, 'damaged in store', null, v_supplier);
    set constraints all immediate;
    select coalesce(sum(b.quantity), 0) into v_sup_q from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_item and b.owner_party_id = v_supplier;
    return query select 'a write-off against the supplier''s position is the supplier''s, with no cost and no journal',
      v_sup_q = 1
      and exists (select 1 from erp.stock_movement m where m.tenant_id = v_tenant and m.item_id = v_item and m.movement_type = 'scrap'
                   and m.owner_party_id = v_supplier and m.unit_cost_minor is null and m.cost_minor is null)
      and (select count(*) from erp.journal j where j.tenant_id = v_tenant and j.source_code = 'stock.adjusted') = v_j,
      format('supplier now owns %s (expected 1); no adjustment journal', v_sup_q);

    -- 7. One door, one function; the device kit still resolves its six arguments.
    return query select 'the write-off door exists once with its seventh argument and the device handler still resolves',
      (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'erp_write_off_stock') = 1
      and (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'erp' and p.proname = 'write_off_stock') = 1
      and to_regprocedure('erp.write_off_stock(uuid,uuid,uuid,numeric,text,uuid,uuid)') is not null
      and not exists (select 1 from erp.device_task_handler_report() r where r.reference like '%write_off_stock%'),
      'one erp_write_off_stock, one erp.write_off_stock, the adjustment handler sound';

    -- 8. Both changes of hands reverse: the keeper comes back, then the owner.
    perform erp.reverse_stock_movement(v_hand, 'consignment suite: custody reversed');
    perform erp.reverse_stock_movement(v_move, 'consignment suite: reversed');
    set constraints all immediate;
    select coalesce(sum(b.quantity), 0) into v_sup_q from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_item and b.owner_party_id = v_supplier;
    select coalesce(sum(b.quantity), 0) into v_co_q from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_item and b.owner_party_id = v_company;
    return query select 'reversing the hand-over and the consumption gives the stock back to the supplier and the positions still agree',
      v_sup_q = 4 and v_co_q = 0
      and (select coalesce(sum(b.quantity), 0) from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_item and b.custody_party_id = v_3pl) = 0
      and not exists (select 1 from erp.stock_reconciliation_report()),
      format('supplier owns %s after the reversals (expected 4), the company %s (expected 0), the provider keeps nothing', v_sup_q, v_co_q);

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.code = 'zzcons'),
    'the organisation and its stock rolled back';
end;
$$;

create or replace function erp_test.assert_consignment_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _consignment on commit drop as
    select * from erp_test.consignment_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _consignment;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_CONSIGNMENT_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_CONSIGNMENT_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('consignment: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_consignment_suite() from public, anon, authenticated;
revoke all on function erp_test.consignment_suite() from public, anon, authenticated;

insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
  ('D9', 'erp_test', 'assert_consignment_suite',
   'Consigned stock consumed changes owner where it stands and posts as a purchase; custody handed to a provider moves the keeper alone; a supplier''s position is written off as the supplier''s.')
on conflict do nothing;

-- The identity policy suite proves a policy proposed by site through the door.
do $identity$
declare
  v_def text;
  v_n1  text := E'  raise exception ''CLOVEERP_SUITE_UNDO'';\n  exception when others then\n    if sqlerrm <> ''CLOVEERP_SUITE_UNDO'' then raise; end if;\n  end;\n\n  -- 10. Undone.';
  v_r1  text := E'  -- 10. A policy proposed by site through the door resolves at that site and nowhere else.\n'
             || E'  v_cases := v_cases + 1;\n'
             || E'  v_cs := erp.create_change_set(''zz-site-policy'', ''Pallets at this site'', ''Proposed from the stock policies screen.'');\n'
             || E'  insert into erp.item (tenant_id, code, name, item_class, stock_uom_id, status)\n'
             || E'  select v_tenant, ''ZZ-FG'', ''Finished item'', ''FG'', u.id, ''active'' from erp.uom u where u.tenant_id = v_tenant and u.is_base limit 1\n'
             || E'  returning id into v_fg;\n'
             || E'  perform erp.propose_identity_policy(''ZZ-SITE-PAL'', ''Pallets at this site'', ''FG'',\n'
             || E'    (select s.code from erp.site s where s.id = v_site), null, ''pallet'', ''hybrid'', current_date, v_cs);\n'
             || E'  perform erp.submit_change_set(v_cs);\n'
             || E'  perform erp.approve_change_set(v_cs);\n'
             || E'  perform erp.promote_change_set(v_cs);\n'
             || E'  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)\n'
             || E'  values (v_tenant, v_entity, ''ZZ-ELSEWHERE'', ''Elsewhere'', ''warehouse'', ''active'') returning id into v_site2;\n'
             || E'  select * into pol from erp.identity_policy_for(v_fg, v_site, ''handling_unit_build'');\n'
             || E'  case_name := ''a policy proposed by site through the door resolves at that site and nowhere else'';\n'
             || E'  passed := pol.identity_level = ''pallet'' and pol.count_method = ''hybrid''\n'
             || E'        and (select p.identity_level from erp.identity_policy_for(v_fg, v_site2, ''handling_unit_build'') p) is distinct from ''pallet''\n'
             || E'        and exists (select 1 from erp.container_identity_policy c where c.tenant_id = v_tenant and c.code = ''ZZ-SITE-PAL'' and c.site_id = v_site and c.status = ''active'')\n'
             || E'        and exists (select 1 from erp.container_identity_policies() cp where cp.code = ''ZZ-SITE-PAL'' and cp.site is not null);\n'
             || E'  detail := format(''at the site: %s / %s; elsewhere: %s'', pol.identity_level, pol.count_method,\n'
             || E'                   (select p.identity_level from erp.identity_policy_for(v_fg, v_site2, ''handling_unit_build'') p));\n'
             || E'  return next;\n\n'
             || E'  raise exception ''CLOVEERP_SUITE_UNDO'';\n  exception when others then\n    if sqlerrm <> ''CLOVEERP_SUITE_UNDO'' then raise; end if;\n  end;\n\n  -- 11. Undone.';
  v_n2  text := E'  pol record;\nbegin';
  v_r2  text := E'  pol record;\n  v_cs uuid; v_site2 uuid; v_fg uuid;\nbegin';
  v_n3  text := E'identity_policy_suite ran % cases, expected 10';
  v_r3  text := E'identity_policy_suite ran % cases, expected 11';
  v_n4  text := E'  if v_cases <> 10 then';
  v_r4  text := E'  if v_cases <> 11 then';
begin
  v_def := pg_get_functiondef('erp_test.identity_policy_suite()'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1
     or (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1
     or (length(v_def) - length(replace(v_def, v_n3, ''))) / length(v_n3) <> 1
     or (length(v_def) - length(replace(v_def, v_n4, ''))) / length(v_n4) <> 1 then
    raise exception 'CLOVEERP_FIXTURE_UNRECOGNISED: erp_test.identity_policy_suite() is not the body this migration re-pins';
  end if;
  execute replace(replace(replace(replace(v_def, v_n1, v_r1), v_n2, v_r2), v_n3, v_r3), v_n4, v_r4);

  v_def := pg_get_functiondef('erp_test.assert_identity_policy_suite()'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n3, ''))) / length(v_n3) <> 1
     or position(E'  if v_all <> 10 then' in v_def) = 0 then
    raise exception 'CLOVEERP_FIXTURE_UNRECOGNISED: erp_test.assert_identity_policy_suite() is not the wrapper this migration re-pins';
  end if;
  execute replace(replace(v_def, v_n3, v_r3), E'  if v_all <> 10 then', E'  if v_all <> 11 then');
end
$identity$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_consignment_suite();
select erp_test.assert_identity_policy_suite();
select erp_test.assert_costing_suite();
select erp_test.assert_ownership_suite();
select erp_test.assert_stock_invariants();
select erp_test.assert_order_behaviour_suite();
select erp_test.assert_device_drain_suite();
select erp_test.assert_part5_register_suite();
select erp_test.assert_module_upgrade_suite();
select erp_test.assert_onboarding_interview_suite();
select erp.assert_guidance_sound();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage('de');

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_linter_clean();

do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
