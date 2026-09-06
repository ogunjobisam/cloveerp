-- =============================================================================
-- An order type has behaviour
--
-- Specification v1.6 §5.3 (v1.2), "purchase order types including blanket,
-- consignment, drop-ship and intercompany". Phase 8, file 2 of 10.
--
-- The register said: "only the standard purchase order is installed and none
-- of the four has behaviour of its own — a blanket order that does not call
-- off is a purchase order with a different name." That was exact. Document
-- types are configuration and a tenant could name four types, but the product
-- did the same thing with each.
--
-- Behaviour lives on the document, not on a new type: erp.document gains
-- order_behaviour_code from a product vocabulary (standard, blanket,
-- consignment, drop_ship, intercompany), settable on a purchase order while
-- it is a draft and fixed once it has committed. Each behaviour then does
-- something the standard order does not:
--
--   blanket      an agreement, not a commitment: it never posts to the ledger;
--                erp.call_off_blanket_order() raises a standard order against
--                it, priced from the blanket, linked `consumes` per line, and
--                refuses a call-off past the agreed quantity or the agreement's
--                validity; erp.blanket_position() says what is left.
--   consignment  goods received against it belong to the supplier until used:
--                erp.receive_against() sets the receipt's stock owner to the
--                supplier, and Phase 4a's ownership rules then keep it off the
--                ledger and out of the valuation while it is counted and held.
--   drop_ship    the supplier delivers to the customer: erp.raise_drop_ship_order()
--                raises the purchase order from a sales order with the customer's
--                address on it, priced from the supplier catalogue, each line
--                linked `converts` to the sales line; erp.confirm_drop_ship()
--                fulfils both sides on the supplier's word with no stock
--                movement; receiving against it is refused.
--   intercompany erp.raise_intercompany_order() (Phase 4c) now stamps the
--                mirror it raises.
--
-- Bodies that change are re-emitted after asserting the deployed text
-- (erp.receive_against, erp.post_document_finance's affects_finance gate,
-- erp.raise_intercompany_order). No enum changes: document_relation_kind
-- already carries `consumes` and `converts`.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The vocabulary and the column
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_ref.order_behaviour (
  code          text primary key check (code ~ '^[a-z][a-z0-9_]*$'),
  name_key      text not null,
  description   text not null,
  seq           integer not null,
  registered_at timestamptz not null default now()
);

comment on table erp_ref.order_behaviour is
  'Specification v1.6 §5.3: what a purchase order does beyond the standard one. '
  'A vocabulary, not configuration: each code has behaviour in the product.';

insert into erp_ref.order_behaviour (code, name_key, description, seq) values
  ('standard',     'order_behaviour.standard.name',     'A commitment to buy: posts to the ledger when sent, received against, invoiced.', 10),
  ('blanket',      'order_behaviour.blanket.name',      'An agreement to buy up to a quantity over a period. Posts nothing; call-offs are the commitments.', 20),
  ('consignment',  'order_behaviour.consignment.name',  'Goods received against it stay the supplier''s until used: held and counted, not owned or valued.', 30),
  ('drop_ship',    'order_behaviour.drop_ship.name',    'The supplier delivers to the customer. Raised from a sales order; fulfilled on the supplier''s word; never received.', 40),
  ('intercompany', 'order_behaviour.intercompany.name', 'The mirror of a sales order in another company of the organisation.', 50)
on conflict (code) do update set name_key = excluded.name_key, description = excluded.description, seq = excluded.seq;

insert into erp_ref.resource (key, locale, value, module_code) values
  ('order_behaviour.standard.name',     'en', 'Standard',     'procurement'),
  ('order_behaviour.standard.name',     'de', 'Standard',     'procurement'),
  ('order_behaviour.blanket.name',      'en', 'Blanket',      'procurement'),
  ('order_behaviour.blanket.name',      'de', 'Rahmen',       'procurement'),
  ('order_behaviour.consignment.name',  'en', 'Consignment',  'procurement'),
  ('order_behaviour.consignment.name',  'de', 'Konsignation', 'procurement'),
  ('order_behaviour.drop_ship.name',    'en', 'Drop-ship',    'procurement'),
  ('order_behaviour.drop_ship.name',    'de', 'Streckengeschäft', 'procurement'),
  ('order_behaviour.intercompany.name', 'en', 'Intercompany', 'procurement'),
  ('order_behaviour.intercompany.name', 'de', 'Konzernintern', 'procurement')
on conflict (key, locale) do update set value = excluded.value;

alter table erp.document
  add column if not exists order_behaviour_code text not null default 'standard'
    references erp_ref.order_behaviour (code);

create or replace function erp.guard_order_behaviour()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_base text;
begin
  if new.order_behaviour_code = 'standard'
     and (tg_op = 'INSERT' or new.order_behaviour_code = old.order_behaviour_code) then
    return new;
  end if;

  select bt.code into v_base
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.tenant_id = new.tenant_id and dt.id = new.document_type_id;

  if new.order_behaviour_code <> 'standard' and v_base <> 'purchase_order' then
    raise exception 'CLOVEERP_BEHAVIOUR_NOT_FOR_TYPE: % is a purchase order behaviour and % is a %',
      new.order_behaviour_code, new.document_number, v_base
      using errcode = '23514',
            hint = 'Blanket, consignment, drop-ship and intercompany are ways a purchase order behaves; a sales order or a receipt has none.';
  end if;

  if tg_op = 'UPDATE' and new.order_behaviour_code is distinct from old.order_behaviour_code
     and exists (select 1 from erp.object_state os join erp.state s on s.id = os.current_state_id
                  where os.tenant_id = new.tenant_id and os.object_type = 'document'
                    and os.object_id = new.id and s.is_committed) then
    raise exception 'CLOVEERP_BEHAVIOUR_FIXED_AFTER_ISSUE: % has committed as a % order and stays one',
      new.document_number, old.order_behaviour_code
      using errcode = '23514',
            hint = 'Cancel the order and raise it again with the behaviour it should have had; what the supplier was sent does not change underneath them.';
  end if;

  return new;
end;
$$;
revoke all on function erp.guard_order_behaviour() from public, anon, authenticated;

drop trigger if exists t_document_order_behaviour on erp.document;
create trigger t_document_order_behaviour
  before insert or update of order_behaviour_code on erp.document
  for each row execute function erp.guard_order_behaviour();

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Setting it
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.set_order_behaviour(p_document_id uuid, p_behaviour text, p_valid_to date default null)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  bt       erp_ref.document_type%rowtype;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;
  select * into dt from erp.document_type where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;
  perform erp.authorise(coalesce(dt.create_permission, bt.create_permission),
                        d.entity_id, d.site_id, null, 'document', p_document_id);

  if not exists (select 1 from erp_ref.order_behaviour b where b.code = p_behaviour) then
    raise exception 'CLOVEERP_UNKNOWN_ORDER_BEHAVIOUR: % is not a behaviour a purchase order has', p_behaviour
      using errcode = '23503',
            hint = 'standard, blanket, consignment, drop_ship or intercompany (erp_ref.order_behaviour).';
  end if;
  if p_behaviour = 'blanket' and p_valid_to is not null and p_valid_to < current_date then
    raise exception 'CLOVEERP_BLANKET_EXPIRED: an agreement valid to % is already over', p_valid_to
      using errcode = '23514', hint = 'Give the date the agreement runs to, or none for open-ended.';
  end if;

  -- The trigger refuses the wrong type and a change after commitment.
  update erp.document
     set order_behaviour_code = p_behaviour,
         attributes = case when p_behaviour = 'blanket'
                           then attributes || jsonb_build_object('blanket', jsonb_strip_nulls(jsonb_build_object('valid_to', p_valid_to)))
                           else attributes - 'blanket' end,
         updated_at = now()
   where id = p_document_id;
end;
$$;

comment on function erp.set_order_behaviour is
  'Specification v1.6 §5.3: names how a draft purchase order behaves. A blanket '
  'carries the date its agreement runs to. Refused on any other document type '
  'and once the order has committed.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Blanket: the agreement, the call-off, the position
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.blanket_position(p_blanket_id uuid)
returns table(line_id uuid, line_no integer, item_id uuid, agreed numeric, called_off numeric,
              remaining numeric, unit_price_minor bigint, valid_to date)
language sql
stable
set search_path = ''
as $$
  select l.id, l.line_no, l.item_id, l.quantity,
         coalesce((select sum(r.quantity) from erp.document_relation r
                     join erp.document c on c.id = r.from_document_id
                    where r.tenant_id = l.tenant_id and r.to_line_id = l.id
                      and r.relation_kind = 'consumes' and not c.is_cancelled), 0),
         l.quantity - coalesce((select sum(r.quantity) from erp.document_relation r
                                  join erp.document c on c.id = r.from_document_id
                                 where r.tenant_id = l.tenant_id and r.to_line_id = l.id
                                   and r.relation_kind = 'consumes' and not c.is_cancelled), 0),
         l.unit_price_minor,
         (d.attributes -> 'blanket' ->> 'valid_to')::date
    from erp.document d
    join erp.document_line l on l.tenant_id = d.tenant_id and l.document_id = d.id and not l.is_cancelled
   where d.tenant_id = erp.require_tenant_id() and d.id = p_blanket_id
     and d.order_behaviour_code = 'blanket'
   order by l.line_no
$$;
revoke all on function erp.blanket_position(uuid) from public, anon, authenticated;

create or replace function erp.call_off_blanket_order(p_blanket_id uuid, p_lines jsonb)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.document%rowtype;
  bdt      erp.document_type%rowtype;
  v_valid  date;
  v_po     uuid;
  v_line   uuid;
  l        jsonb;
  pos      record;
  v_qty    numeric;
  v_n      integer := 0;
begin
  select * into b from erp.document where tenant_id = v_tenant and id = p_blanket_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_blanket_id using errcode = '23503';
  end if;
  if b.order_behaviour_code <> 'blanket' then
    raise exception 'CLOVEERP_NOT_A_BLANKET_ORDER: % is a % order', b.document_number, b.order_behaviour_code
      using errcode = '23514', hint = 'Call off against a blanket order; raise a standard order for anything else.';
  end if;
  if b.is_cancelled then
    raise exception 'CLOVEERP_DOCUMENT_CANCELLED: % is cancelled', b.document_number using errcode = '23514';
  end if;
  v_valid := (b.attributes -> 'blanket' ->> 'valid_to')::date;
  if v_valid is not null and v_valid < current_date then
    raise exception 'CLOVEERP_BLANKET_EXPIRED: % ran to % and has ended', b.document_number, v_valid
      using errcode = '23514', hint = 'Agree a new blanket order with the supplier, or raise a standard order.';
  end if;
  if coalesce(jsonb_array_length(p_lines), 0) = 0 then
    raise exception 'CLOVEERP_CALL_OFF_HAS_NO_LINES: a call-off names at least one blanket line and a quantity'
      using errcode = '23514', hint = 'Pass [{"line_id": …, "quantity": …, "required_date": …}].';
  end if;

  select * into bdt from erp.document_type where tenant_id = v_tenant and id = b.document_type_id;
  perform erp.authorise('procurement.order', b.entity_id, b.site_id, null, 'document', p_blanket_id);

  v_po := erp.open_document(bdt.code, b.party_id, b.entity_id, b.site_id, b.document_number, null, b.currency);
  update erp.document
     set our_reference = b.document_number,
         notes = format('Call-off against blanket order %s', b.document_number),
         updated_at = now()
   where id = v_po;

  for l in select * from jsonb_array_elements(p_lines) loop
    select * into pos from erp.blanket_position(p_blanket_id) p where p.line_id = (l ->> 'line_id')::uuid;
    if not found then
      raise exception 'CLOVEERP_UNKNOWN_LINE: % is not a line of %', l ->> 'line_id', b.document_number
        using errcode = '23503', hint = 'Name a line of the blanket order (erp_blanket_position lists them).';
    end if;
    v_qty := (l ->> 'quantity')::numeric;
    if coalesce(v_qty, 0) <= 0 then
      raise exception 'CLOVEERP_CALL_OFF_HAS_NO_LINES: line % calls off nothing', pos.line_no
        using errcode = '23514', hint = 'Give a positive quantity.';
    end if;
    if v_qty > pos.remaining then
      raise exception 'CLOVEERP_BLANKET_EXHAUSTED: % of % already called off on line %; % asked, % left',
        pos.called_off, pos.agreed, pos.line_no, v_qty, pos.remaining
        using errcode = '23514',
              hint = 'Call off what is left, amend the blanket order''s agreed quantity, or raise a standard order for the rest.';
    end if;
    v_line := erp.add_document_line(v_po, pos.item_id, v_qty, pos.unit_price_minor,
                                    format('Call-off against %s line %s', b.document_number, pos.line_no),
                                    (l ->> 'required_date')::date);
    insert into erp.document_relation (tenant_id, from_document_id, to_document_id, relation_kind,
                                       from_line_id, to_line_id, quantity)
    values (v_tenant, v_po, p_blanket_id, 'consumes', v_line, pos.line_id, v_qty);
    v_n := v_n + 1;
  end loop;

  perform erp.append_event('document.call_off_raised', 'document', v_po,
    jsonb_build_object('blanket_order_id', p_blanket_id, 'blanket_order_number', b.document_number,
                       'call_off_number', (select document_number from erp.document where id = v_po),
                       'lines', v_n),
    b.entity_id, b.site_id);

  return v_po;
end;
$$;

comment on function erp.call_off_blanket_order is
  'Specification v1.6 §5.3: raises a standard purchase order against a blanket '
  'agreement — the same supplier, company, site and currency, each line priced '
  'from the blanket line and linked to it as consumed — and refuses a call-off '
  'past what was agreed or past the agreement''s validity. The call-off is the '
  'commitment; the blanket never posts.';

-- The blanket posts nothing. transition_document() asks the finance bridge on
-- every committed transition and the bridge answers for itself.
do $$
declare v_src text := pg_get_functiondef('erp.post_document_finance(uuid)'::regprocedure);
begin
  if position(E'  if not bt.affects_finance then\n    return null;\n  end if;' in v_src) = 0
     or position('order_behaviour_code' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.post_document_finance does not carry the affects_finance gate this file needles';
  end if;
  execute replace(v_src,
    E'  if not bt.affects_finance then\n    return null;\n  end if;',
    E'  if not bt.affects_finance then\n    return null;\n  end if;\n\n'
    '  -- §5.3: a blanket order is an agreement, not a commitment. The call-offs\n'
    '  -- raised against it are what reach the ledger.\n'
    '  if d.order_behaviour_code = ''blanket'' then\n'
    '    return null;\n'
    '  end if;');
end $$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Consignment and drop-ship at the receiving bay
-- ═════════════════════════════════════════════════════════════════════════════

do $$
declare v_src text := pg_get_functiondef('erp.receive_against(uuid,uuid,numeric,uuid)'::regprocedure);
begin
  if position(E'  perform erp.authorise(''procurement.receive'', rd.entity_id, rd.site_id, null,\n                        ''document'', p_receipt_id);' in v_src) = 0
     or position('order_behaviour_code' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.receive_against is not the 20260905 body';
  end if;
  execute replace(v_src,
    E'  perform erp.authorise(''procurement.receive'', rd.entity_id, rd.site_id, null,\n                        ''document'', p_receipt_id);',
    E'  perform erp.authorise(''procurement.receive'', rd.entity_id, rd.site_id, null,\n                        ''document'', p_receipt_id);\n\n'
    '  -- §5.3: what the order''s behaviour says about the goods arriving.\n'
    '  if od.order_behaviour_code = ''drop_ship'' then\n'
    '    raise exception ''CLOVEERP_DROP_SHIP_NOT_RECEIVED: % is delivered by the supplier to the customer and never arrives here'', od.document_number\n'
    '      using errcode = ''23514'',\n'
    '            hint = ''Confirm the delivery on the supplier''''s word with erp_confirm_drop_ship; nothing is received into stock.'';\n'
    '  end if;\n'
    '  if od.order_behaviour_code = ''consignment'' then\n'
    '    if rd.stock_owner_party_id is null then\n'
    '      update erp.document set stock_owner_party_id = od.party_id, updated_at = now() where id = p_receipt_id;\n'
    '      rd.stock_owner_party_id := od.party_id;\n'
    '    elsif rd.stock_owner_party_id <> od.party_id then\n'
    '      raise exception ''CLOVEERP_OWNER_CONFLICT: receipt % is owned by another party and % is consigned by its supplier'', rd.document_number, od.document_number\n'
    '        using errcode = ''23514'',\n'
    '              hint = ''Receive consigned goods on a receipt of their own; one receipt has one stock owner.'';\n'
    '    end if;\n'
    '  end if;');
end $$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Drop-ship
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.raise_drop_ship_order(p_sales_order_id uuid, p_supplier_party_id uuid)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  so       erp.document%rowtype;
  sdt      erp.document_type%rowtype;
  v_type   text;
  v_po     uuid;
  v_line   uuid;
  l        record;
  v_n      integer := 0;
begin
  select * into so from erp.document where tenant_id = v_tenant and id = p_sales_order_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_sales_order_id using errcode = '23503';
  end if;
  select * into sdt from erp.document_type where tenant_id = v_tenant and id = so.document_type_id;
  if sdt.base_type_code <> 'sales_order' then
    raise exception 'CLOVEERP_NOT_A_SALES_ORDER: % is a %', so.document_number, sdt.code
      using errcode = '23514', hint = 'A drop-ship order is raised from the sales order the supplier will deliver.';
  end if;
  if so.is_cancelled then
    raise exception 'CLOVEERP_DOCUMENT_CANCELLED: % is cancelled', so.document_number using errcode = '23514';
  end if;
  if not exists (select 1 from erp.party_role pr
                  where pr.tenant_id = v_tenant and pr.party_id = p_supplier_party_id
                    and pr.role_kind = 'supplier' and pr.status = 'active') then
    raise exception 'CLOVEERP_NOT_A_SUPPLIER: % has no active supplier role', p_supplier_party_id
      using errcode = '23503', hint = 'Give the party a supplier role before buying from them.';
  end if;
  if exists (select 1 from erp.document_relation rel
              join erp.document po on po.id = rel.from_document_id
             where rel.tenant_id = v_tenant and rel.to_document_id = p_sales_order_id
               and rel.relation_kind = 'converts' and po.order_behaviour_code = 'drop_ship' and not po.is_cancelled) then
    raise exception 'CLOVEERP_ALREADY_DROP_SHIPPED: % already has a drop-ship purchase order', so.document_number
      using errcode = '23505', hint = 'Open the linked purchase order; cancel it first if it must be raised again.';
  end if;

  perform erp.authorise('procurement.order', so.entity_id, so.site_id, null, 'document', p_sales_order_id);

  select dt.code into v_type from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.base_type_code = 'purchase_order' and dt.status = 'active'
   order by (dt.entity_id = so.entity_id) desc, (dt.entity_id is null) desc, dt.code
   limit 1;
  if v_type is null then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT_TYPE: no purchase order type is configured'
      using errcode = '23503', hint = 'Install the procurement module (erp.configure_procurement) before raising drop-ship orders.';
  end if;

  v_po := erp.open_document(v_type, p_supplier_party_id, so.entity_id, so.site_id,
                            so.document_number, so.required_date, so.currency);
  update erp.document
     set order_behaviour_code = 'drop_ship',
         address_snapshot = so.address_snapshot,
         our_reference = so.document_number,
         notes = format('Drop-ship for sales order %s: deliver to the customer', so.document_number),
         updated_at = now()
   where id = v_po;

  for l in
    select dl.id, dl.item_id, dl.quantity, dl.description, dl.required_date
      from erp.document_line dl
     where dl.tenant_id = v_tenant and dl.document_id = p_sales_order_id and not dl.is_cancelled
     order by dl.line_no
  loop
    -- Priced from the supplier catalogue by add_document_line (Phase 8, file 1);
    -- a line the catalogue cannot price stays at zero until somebody prices it.
    v_line := erp.add_document_line(v_po, l.item_id, l.quantity, 0, l.description, l.required_date);
    insert into erp.document_relation (tenant_id, from_document_id, to_document_id, relation_kind,
                                       from_line_id, to_line_id, quantity)
    values (v_tenant, v_po, p_sales_order_id, 'converts', v_line, l.id, l.quantity);
    v_n := v_n + 1;
  end loop;

  perform erp.append_event('document.drop_ship_raised', 'document', v_po,
    jsonb_build_object('sales_order_id', p_sales_order_id, 'sales_order_number', so.document_number,
                       'purchase_order_number', (select document_number from erp.document where id = v_po),
                       'supplier_party_id', p_supplier_party_id, 'lines', v_n),
    so.entity_id, so.site_id);

  return v_po;
end;
$$;

comment on function erp.raise_drop_ship_order is
  'Specification v1.6 §5.3: a purchase order the supplier fulfils straight to '
  'the customer. Raised from the sales order with the customer''s address on '
  'it, each line priced from the supplier catalogue and linked to the sales '
  'line it converts. Nothing about it is ever received into stock.';

create or replace function erp.confirm_drop_ship(p_purchase_order_id uuid, p_delivered_on date default null, p_reference text default null)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  po       erp.document%rowtype;
  v_so     uuid;
  v_n      integer := 0;
  rel      record;
begin
  select * into po from erp.document where tenant_id = v_tenant and id = p_purchase_order_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_purchase_order_id using errcode = '23503';
  end if;
  if po.order_behaviour_code <> 'drop_ship' then
    raise exception 'CLOVEERP_NOT_A_DROP_SHIP_ORDER: % is a % order', po.document_number, po.order_behaviour_code
      using errcode = '23514', hint = 'A standard order is received at the bay (erp_receive_against); only a drop-ship is confirmed on the supplier''s word.';
  end if;
  perform erp.authorise('procurement.receive', po.entity_id, po.site_id, null, 'document', p_purchase_order_id);

  for rel in
    select r.from_line_id, r.to_line_id, r.to_document_id, r.quantity
      from erp.document_relation r
     where r.tenant_id = v_tenant and r.from_document_id = p_purchase_order_id and r.relation_kind = 'converts'
       and r.from_line_id is not null
  loop
    update erp.document_line set quantity_fulfilled = quantity, updated_at = now()
     where id in (rel.from_line_id, rel.to_line_id) and coalesce(quantity_fulfilled, 0) < quantity;
    v_so := rel.to_document_id;
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then
    raise exception 'CLOVEERP_DROP_SHIP_HAS_NO_LINES: % converts no sales line', po.document_number
      using errcode = '23514', hint = 'A drop-ship order is raised from a sales order with lines; this one has none to fulfil.';
  end if;

  update erp.document
     set attributes = attributes || jsonb_build_object('drop_ship', jsonb_strip_nulls(jsonb_build_object(
                        'delivered_on', coalesce(p_delivered_on, current_date), 'reference', p_reference))),
         updated_at = now()
   where id = p_purchase_order_id;

  perform erp.append_event('document.drop_shipped', 'document', p_purchase_order_id,
    jsonb_build_object('sales_order_id', v_so, 'purchase_order_number', po.document_number,
                       'delivered_on', coalesce(p_delivered_on, current_date), 'reference', p_reference, 'lines', v_n),
    po.entity_id, po.site_id);
end;
$$;

comment on function erp.confirm_drop_ship is
  'Specification v1.6 §5.3: the supplier says the customer has the goods. Both '
  'the purchase lines and the sales lines they convert are fulfilled; no stock '
  'moves, because none ever came here.';

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current) values
  ('document.call_off_raised', 1, 'document', 'procurement', 'event.document.call_off_raised',
   'A standard purchase order was raised against a blanket agreement; each line consumes a blanket line.',
   '{"type":"object","required":["blanket_order_id","blanket_order_number","call_off_number","lines"],
     "properties":{"blanket_order_id":{"type":"string"},"blanket_order_number":{"type":"string"},
                   "call_off_number":{"type":"string"},"lines":{"type":"integer"}}}', true),
  ('document.drop_ship_raised', 1, 'document', 'procurement', 'event.document.drop_ship_raised',
   'A purchase order the supplier delivers to the customer was raised from a sales order.',
   '{"type":"object","required":["sales_order_id","sales_order_number","purchase_order_number","supplier_party_id","lines"],
     "properties":{"sales_order_id":{"type":"string"},"sales_order_number":{"type":"string"},
                   "purchase_order_number":{"type":"string"},"supplier_party_id":{"type":"string"},"lines":{"type":"integer"}}}', true),
  ('document.drop_shipped', 1, 'document', 'procurement', 'event.document.drop_shipped',
   'The supplier delivered a drop-ship order to the customer; purchase and sales lines are fulfilled without a stock movement.',
   '{"type":"object","required":["sales_order_id","purchase_order_number","delivered_on","lines"],
     "properties":{"sales_order_id":{"type":"string"},"purchase_order_number":{"type":"string"},
                   "delivered_on":{"type":"string"},"reference":{"type":"string"},"lines":{"type":"integer"}}}', true)
on conflict (code, version) do update
  set description = excluded.description, payload_schema = excluded.payload_schema, is_current = excluded.is_current;

insert into erp_ref.resource (key, locale, value, module_code) values
  ('event.document.call_off_raised',  'en', 'Call-off raised against a blanket order', 'procurement'),
  ('event.document.call_off_raised',  'de', 'Abruf aus Rahmenbestellung erstellt', 'procurement'),
  ('event.document.drop_ship_raised', 'en', 'Drop-ship order raised from a sales order', 'procurement'),
  ('event.document.drop_ship_raised', 'de', 'Streckenbestellung aus Kundenauftrag erstellt', 'procurement'),
  ('event.document.drop_shipped',     'en', 'Drop-ship delivered to the customer', 'procurement'),
  ('event.document.drop_shipped',     'de', 'Streckenlieferung beim Kunden eingegangen', 'procurement')
on conflict (key, locale) do update set value = excluded.value;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The intercompany mirror says what it is
-- ═════════════════════════════════════════════════════════════════════════════

do $$
declare v_src text := pg_get_functiondef('erp.raise_intercompany_order(uuid,uuid)'::regprocedure);
begin
  if position('notes = format(''Mirror of sales order %s raised by %s'', so.document_number, v_seller.code),' in v_src) = 0
     or position('order_behaviour_code' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.raise_intercompany_order is not the 20260906082000 body';
  end if;
  execute replace(v_src,
    'notes = format(''Mirror of sales order %s raised by %s'', so.document_number, v_seller.code),',
    E'order_behaviour_code = ''intercompany'',\n         notes = format(''Mirror of sales order %s raised by %s'', so.document_number, v_seller.code),');
end $$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Doors
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_set_order_behaviour(p_document_id uuid, p_behaviour text, p_valid_to date default null)
returns void language sql set search_path = '' as $$
  select erp.set_order_behaviour(p_document_id, p_behaviour, p_valid_to);
$$;
create or replace function public.erp_blanket_position(p_blanket_id uuid)
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(p) order by p.line_no), '[]'::jsonb) from erp.blanket_position(p_blanket_id) p;
$$;
create or replace function public.erp_call_off_blanket_order(p_blanket_id uuid, p_lines jsonb)
returns uuid language sql set search_path = '' as $$
  select erp.call_off_blanket_order(p_blanket_id, p_lines);
$$;
create or replace function public.erp_raise_drop_ship_order(p_sales_order_id uuid, p_supplier_party_id uuid)
returns uuid language sql set search_path = '' as $$
  select erp.raise_drop_ship_order(p_sales_order_id, p_supplier_party_id);
$$;
create or replace function public.erp_confirm_drop_ship(p_purchase_order_id uuid, p_delivered_on date default null, p_reference text default null)
returns void language sql set search_path = '' as $$
  select erp.confirm_drop_ship(p_purchase_order_id, p_delivered_on, p_reference);
$$;
create or replace function public.erp_order_behaviours()
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', b.code, 'name', erp.text(b.name_key), 'description', b.description) order by b.seq), '[]'::jsonb)
    from erp_ref.order_behaviour b;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'erp_set_order_behaviour(uuid, text, date)',
    'erp_blanket_position(uuid)',
    'erp_call_off_blanket_order(uuid, jsonb)',
    'erp_raise_drop_ship_order(uuid, uuid)',
    'erp_confirm_drop_ship(uuid, date, text)',
    'erp_order_behaviours()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_set_order_behaviour', 'erp.set_order_behaviour',
   'Names how a draft purchase order behaves; authorised under the permission that raised the document.'),
  ('erp_call_off_blanket_order', 'erp.call_off_blanket_order',
   'Raises a standard purchase order against a blanket agreement; authorises procurement.order.'),
  ('erp_raise_drop_ship_order', 'erp.raise_drop_ship_order',
   'Raises a drop-ship purchase order from a sales order; authorises procurement.order.'),
  ('erp_confirm_drop_ship', 'erp.confirm_drop_ship',
   'Fulfils a drop-ship order on the supplier''s word; authorises procurement.receive.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The register
-- ═════════════════════════════════════════════════════════════════════════════

update erp_ref.part5_capability
   set status = 'built',
       gap = null,
       artefacts = array['erp.document_type', 'erp_ref.order_behaviour',
                         'erp.set_order_behaviour(uuid,text,date)',
                         'erp.call_off_blanket_order(uuid,jsonb)', 'erp.blanket_position(uuid)',
                         'erp.raise_drop_ship_order(uuid,uuid)', 'erp.confirm_drop_ship(uuid,date,text)',
                         'erp.raise_intercompany_order(uuid,uuid)',
                         'erp.receive_against(uuid,uuid,numeric,uuid)']
 where code = '5.3.order_types';

-- D9 (ownership and custody) is also carried by the consignment receipt here.
insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
  ('D9', 'erp_test', 'assert_order_behaviour_suite',
   'D9: a consignment purchase order''s receipt is owned by the supplier and held by the company; the ledger and the valuation leave it alone.')
on conflict (decision_code, schema_name, routine_name) do update set note = excluded.note;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.order_behaviour_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid; v_admin uuid; v_token text;
  v_auth uuid := gen_random_uuid();
  v_entity uuid; v_company uuid; v_site uuid; v_recv uuid;
  v_sup uuid; v_sup2 uuid; v_cust uuid; v_item uuid; v_item2 uuid; v_uom uuid;
  v_b uuid; v_bl uuid; v_std uuid; v_co uuid; v_col uuid; v_so uuid; v_sol uuid;
  v_cons uuid; v_consl uuid; v_grn uuid; v_grn2 uuid; v_ds uuid; v_dsl uuid;
  v_eu uuid; v_eu_party uuid; v_eu_site uuid; v_ico uuid; v_mirror uuid;
  t record; pos record;
  v_ok boolean; v_msg text; v_n integer; v_owner uuid; v_keeper uuid;
begin
  begin
    select x.tenant_id, x.admin_user_id, x.admin_token into v_tenant, v_admin, v_token
      from erp.provision_tenant('zzob', 'Order Behaviour', 'admin@zzob.test', 'OB Admin') x;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (v_auth, 'admin@zzob.test');
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    perform erp.claim_invitation(v_token);
    perform erp.ensure_demo_configuration(v_tenant, v_admin);

    select e.id, e.party_id into v_entity, v_company from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
    select s.id into v_site from erp.site s where s.tenant_id = v_tenant and s.entity_id = v_entity order by s.code limit 1;
    select l.id into v_recv from erp.location l where l.tenant_id = v_tenant and l.site_id = v_site and l.location_type = 'receiving' order by l.code limit 1;
    select i.id into v_item from erp.item i where i.tenant_id = v_tenant and i.status = 'active' order by i.code limit 1;
    select i.id into v_item2 from erp.item i where i.tenant_id = v_tenant and i.status = 'active' order by i.code offset 1 limit 1;
    select i.stock_uom_id into v_uom from erp.item i where i.id = v_item;
    select pr.party_id into v_sup from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'supplier' order by pr.party_id limit 1;
    select pr.party_id into v_sup2 from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'supplier' order by pr.party_id offset 1 limit 1;
    select pr.party_id into v_cust from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'customer' order by pr.party_id limit 1;

    -- A catalogue price for the drop-ship line to be priced from.
    insert into erp.item_price (tenant_id, item_id, price_kind, price_list_code, party_role_id, currency, amount_minor, per_quantity, uom_id, min_quantity, valid_from)
    select v_tenant, v_item, 'purchase_list', 'ZZOB-LIST', pr.id, 'GBP', 777, 1, v_uom, 0, current_date - 1
      from erp.party_role pr where pr.tenant_id = v_tenant and pr.party_id = v_sup and pr.role_kind = 'supplier';

    -- 1. The vocabulary.
    return query select 'five behaviours, named in both languages',
      (select count(*) from erp_ref.order_behaviour) = 5
      and not exists (select 1 from erp_ref.order_behaviour b
                       where not exists (select 1 from erp_ref.resource r where r.key = b.name_key and r.locale = 'de')),
      'standard, blanket, consignment, drop_ship, intercompany';

    -- 2. Not on a sales order.
    v_so := erp.open_document('sales_order', v_cust, v_entity, v_site);
    v_sol := erp.add_document_line(v_so, v_item, 4, 1500, 'to be drop-shipped');
    begin
      perform erp.set_order_behaviour(v_so, 'blanket');
      v_ok := false; v_msg := 'a sales order became a blanket order';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BEHAVIOUR_NOT_FOR_TYPE%'; v_msg := left(sqlerrm, 70);
    end;
    return query select 'a behaviour is refused on anything but a purchase order', v_ok, v_msg;
    begin
      perform erp.set_order_behaviour(v_so, 'teleport');
      v_ok := false; v_msg := 'an unknown behaviour was accepted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_UNKNOWN_ORDER_BEHAVIOUR%'; v_msg := left(sqlerrm, 70);
    end;
    return query select 'an unknown behaviour is refused', v_ok, v_msg;

    -- 3. A blanket: agreed quantities, a validity, and no journal when sent.
    v_b := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_bl := erp.add_document_line(v_b, v_item, 100, 500, 'agreed for the year');
    perform erp.set_order_behaviour(v_b, 'blanket', current_date + 180);
    return query select 'a purchase order becomes a blanket with the date its agreement runs to',
      (select d.order_behaviour_code = 'blanket' and (d.attributes -> 'blanket' ->> 'valid_to')::date = current_date + 180
         from erp.document d where d.id = v_b),
      'blanket, valid 180 days';

    perform erp.transition_document(v_b, 'submit');
    for t in select tk.id from erp.approval_task tk join erp.approval_request q on q.id = tk.approval_request_id
              where q.object_id = v_b and tk.status = 'pending' and tk.assignee_user_id = erp.current_principal_id()
    loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;
    perform erp.transition_document(v_b, 'approve');
    perform erp.transition_document(v_b, 'send');
    v_std := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_std, v_item, 1, 500, 'a standard order, for contrast');
    perform erp.transition_document(v_std, 'submit');
    for t in select tk.id from erp.approval_task tk join erp.approval_request q on q.id = tk.approval_request_id
              where q.object_id = v_std and tk.status = 'pending' and tk.assignee_user_id = erp.current_principal_id()
    loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;
    perform erp.transition_document(v_std, 'approve');
    perform erp.transition_document(v_std, 'send');
    return query select 'a blanket order sent posts nothing; a standard order sent posts its commitment',
      not exists (select 1 from erp.journal j where j.tenant_id = v_tenant and j.document_id = v_b)
      and exists (select 1 from erp.journal j where j.tenant_id = v_tenant and j.document_id = v_std),
      'an agreement is not a commitment';

    begin
      perform erp.set_order_behaviour(v_b, 'standard');
      v_ok := false; v_msg := 'a sent blanket changed its behaviour';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BEHAVIOUR_FIXED_AFTER_ISSUE%'; v_msg := left(sqlerrm, 70);
    end;
    return query select 'behaviour is fixed once the order has committed', v_ok, v_msg;

    -- 4. Call-offs.
    v_co := erp.call_off_blanket_order(v_b, jsonb_build_array(jsonb_build_object('line_id', v_bl, 'quantity', 30, 'required_date', current_date + 7)));
    select l.id into v_col from erp.document_line l where l.document_id = v_co;
    return query select 'a call-off is a standard order priced from the blanket, linked as consuming the blanket line',
      (select d.order_behaviour_code = 'standard' and d.party_id = v_sup and d.our_reference = (select document_number from erp.document where id = v_b)
         from erp.document d where d.id = v_co)
      and (select l.unit_price_minor = 500 and l.quantity = 30 and l.required_date = current_date + 7 from erp.document_line l where l.id = v_col)
      and exists (select 1 from erp.document_relation r where r.from_document_id = v_co and r.to_document_id = v_b
                   and r.relation_kind = 'consumes' and r.from_line_id = v_col and r.to_line_id = v_bl and r.quantity = 30)
      and exists (select 1 from erp.event e where e.tenant_id = v_tenant and e.aggregate_id = v_co and e.event_type = 'document.call_off_raised'),
      '30 of 100 at 500';
    select * into pos from erp.blanket_position(v_b);
    return query select 'the blanket position counts what was called off and what is left',
      pos.agreed = 100 and pos.called_off = 30 and pos.remaining = 70 and pos.valid_to = current_date + 180,
      format('agreed %s, called off %s, remaining %s', pos.agreed, pos.called_off, pos.remaining);

    begin
      perform erp.call_off_blanket_order(v_b, jsonb_build_array(jsonb_build_object('line_id', v_bl, 'quantity', 71)));
      v_ok := false; v_msg := 'a call-off past the agreement was accepted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BLANKET_EXHAUSTED%'; v_msg := left(sqlerrm, 80);
    end;
    return query select 'a call-off past what is left is refused, and says how much is left', v_ok, v_msg;

    update erp.document set attributes = attributes || jsonb_build_object('blanket', jsonb_build_object('valid_to', current_date - 1)) where id = v_b;
    begin
      perform erp.call_off_blanket_order(v_b, jsonb_build_array(jsonb_build_object('line_id', v_bl, 'quantity', 1)));
      v_ok := false; v_msg := 'a call-off against an ended agreement was accepted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BLANKET_EXPIRED%'; v_msg := left(sqlerrm, 70);
    end;
    return query select 'a call-off against an agreement that has ended is refused', v_ok, v_msg;
    begin
      perform erp.call_off_blanket_order(v_std, jsonb_build_array(jsonb_build_object('line_id', v_bl, 'quantity', 1)));
      v_ok := false; v_msg := 'a standard order took a call-off';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_NOT_A_BLANKET_ORDER%'; v_msg := left(sqlerrm, 70);
    end;
    return query select 'only a blanket takes a call-off', v_ok, v_msg;

    -- 5. Consignment: the receipt belongs to the supplier.
    v_cons := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_consl := erp.add_document_line(v_cons, v_item2, 20, 900, 'on consignment');
    perform erp.set_order_behaviour(v_cons, 'consignment');
    v_grn := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_grn, v_consl, 20);
    update erp.document_line set location_id = coalesce(location_id, v_recv) where document_id = v_grn;
    perform erp.transition_document(v_grn, 'post', 'order behaviour suite');
    set constraints all immediate;
    select m.owner_party_id, m.custody_party_id into v_owner, v_keeper
      from erp.stock_movement m where m.tenant_id = v_tenant and m.document_id = v_grn limit 1;
    return query select 'goods received against a consignment order are owned by the supplier, held by the company, and reach no ledger',
      (select d.stock_owner_party_id = v_sup from erp.document d where d.id = v_grn)
      and v_owner = v_sup and v_keeper = v_company
      and not exists (select 1 from erp.journal j where j.tenant_id = v_tenant and j.document_id = v_grn),
      format('owner is supplier: %s, keeper is company: %s', v_owner = v_sup, v_keeper = v_company);

    v_grn2 := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    update erp.document set stock_owner_party_id = v_sup2 where id = v_grn2;
    begin
      perform erp.receive_against(v_grn2, v_consl, 1);
      v_ok := false; v_msg := 'a receipt owned by another party took consigned goods';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_OWNER_CONFLICT%'; v_msg := left(sqlerrm, 70);
    end;
    return query select 'a receipt already owned by somebody else refuses consigned goods', v_ok, v_msg;

    -- 6. Drop-ship.
    v_ds := erp.raise_drop_ship_order(v_so, v_sup);
    select l.id into v_dsl from erp.document_line l where l.document_id = v_ds;
    return query select 'a drop-ship order is raised from the sales order with the customer''s address, priced from the catalogue, lines linked',
      (select d.order_behaviour_code = 'drop_ship' and d.party_id = v_sup and d.address_snapshot is not distinct from so.address_snapshot
              and d.our_reference = so.document_number
         from erp.document d, erp.document so where d.id = v_ds and so.id = v_so)
      and (select l.unit_price_minor = 777 and l.quantity = 4 from erp.document_line l where l.id = v_dsl)
      and exists (select 1 from erp.document_relation r where r.from_document_id = v_ds and r.to_document_id = v_so
                   and r.relation_kind = 'converts' and r.from_line_id = v_dsl and r.to_line_id = v_sol),
      'priced 777 from the supplier list';
    begin
      perform erp.raise_drop_ship_order(v_so, v_sup);
      v_ok := false; v_msg := 'a second drop-ship order was raised';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_ALREADY_DROP_SHIPPED%'; v_msg := left(sqlerrm, 70);
    end;
    return query select 'a sales order is drop-shipped once', v_ok, v_msg;
    begin
      perform erp.receive_against(v_grn2, v_dsl, 1);
      v_ok := false; v_msg := 'a drop-ship line was received into stock';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_DROP_SHIP_NOT_RECEIVED%'; v_msg := left(sqlerrm, 70);
    end;
    return query select 'a drop-ship line cannot be received into stock', v_ok, v_msg;
    perform erp.confirm_drop_ship(v_ds, current_date, 'carrier ref 42');
    return query select 'confirming the delivery fulfils both sides without a stock movement',
      (select l.quantity_fulfilled = 4 from erp.document_line l where l.id = v_dsl)
      and (select l.quantity_fulfilled = 4 from erp.document_line l where l.id = v_sol)
      and not exists (select 1 from erp.stock_movement m where m.tenant_id = v_tenant and m.document_id = v_ds)
      and exists (select 1 from erp.event e where e.tenant_id = v_tenant and e.aggregate_id = v_ds and e.event_type = 'document.drop_shipped'),
      'fulfilled on the supplier''s word';

    -- 7. Intercompany, stamped.
    v_eu := erp.create_entity('ZZOB-EU', 'Zzob Europe', 'Zzob Europe BV', 'GBP', 'NL', 'en', 'en', 1::smallint);
    select e.party_id into v_eu_party from erp.entity e where e.id = v_eu;
    v_eu_site := erp.create_site('ZZOB-EU-WH', 'Zzob Europe warehouse', 'warehouse', v_eu);
    v_ico := erp.open_document('sales_order', v_eu_party, v_entity, v_site, 'interco', null, null);
    perform erp.add_document_line(v_ico, v_item, 2, 1000, 'intercompany');
    v_mirror := erp.raise_intercompany_order(v_ico, v_eu_site);
    return query select 'the mirror of an intercompany sales order is stamped intercompany',
      (select d.order_behaviour_code from erp.document d where d.id = v_mirror) = 'intercompany', 'stamped by raise_intercompany_order';

    -- 8. The register.
    return query select 'the register says order types are built, and the artefacts exist',
      (select c.status from erp_ref.part5_capability c where c.code = '5.3.order_types') = 'built'
      and not exists (select 1 from erp.part5_coverage_report() f where f.reference = '5.3.order_types'),
      '5.3.order_types';

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant tn where tn.code = 'zzob');
  detail := 'the organisation and its orders rolled back';
  return next;
end;
$$;

create or replace function erp_test.assert_order_behaviour_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 20;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _order_behaviour on commit drop as
    select * from erp_test.order_behaviour_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _order_behaviour;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_ORDER_BEHAVIOUR_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_ORDER_BEHAVIOUR_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('order behaviour: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_order_behaviour_suite() from public, anon, authenticated;
revoke all on function erp_test.order_behaviour_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 10. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_order_behaviour_suite();
select erp_test.assert_ownership_suite();
select erp_test.assert_intercompany_suite();
select erp_test.assert_procurement_suite();
select erp.assert_part5_coverage();
select erp.assert_resource_coverage();
select erp.assert_resource_coverage_de();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_no_dead_configuration();
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
