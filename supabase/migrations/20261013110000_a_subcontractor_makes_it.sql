-- A subcontractor makes it.
--
-- Manufacturing depth, part 4 of 4 (theme 3, owner, 13 October 2026). A
-- company that has a product made by somebody else, from components it sends
-- them, could hand the components over ("Pass on") and buy the product back on
-- a purchase order; but the components stayed in its books with the
-- subcontractor for ever, and the product was valued at the subcontractor's
-- charge alone, as if the components had cost nothing.
--
-- ── DECISIONS (taken under the owner's standing approval) ───────────────────
--
--   * The subcontractor is bought from as any supplier is: a purchase order
--     for the finished product at the price of the work, received, matched to
--     their bill and paid by the payment run. Nothing about paying them is new.
--   * The components go to them as stock in their keeping, by the custody
--     hand-over that already exists, so stock with keepers lists them.
--   * As the product is received, what it is made of comes out of the
--     subcontractor's keeping and its value lands on the product received:
--     the product costs the work plus the components. What cannot land (goods
--     already gone, a standard-costed product) goes to cost of sales, as a
--     landed cost's does. No new account, document type or posting rule.
--   * A receipt the components sent do not cover is refused, rather than
--     taken in at less than it cost.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.subcontract_line: a purchase order line that a subcontractor makes
--      from components sent, with the bill it is made to.
--   B. erp_raise_subcontract_order: the purchase order, at the price of the
--      work, for the product made to its bill in force.
--   C. erp_send_subcontract_components: what the order needs, handed into the
--      subcontractor's keeping.
--   D. erp.consume_for_subcontract, as a goods receipt posts: the components
--      consumed from the subcontractor's keeping and their value landed on
--      the product, in one journal, subcontract.components_consumed.
--   E. erp_subcontract_orders lists the orders, what has come back, and what
--      the subcontractor still holds for them.
--   F. erp_test.subcontract_suite proves A to E.

-- ─────────────────────────────────────────────────────────────────────────────
-- A. A line a subcontractor makes
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists erp.subcontract_line (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references erp.tenant(id) on delete cascade,
  order_line_id uuid not null,
  bom_id        uuid not null,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  constraint subcontract_line_tenant_id_id_key unique (tenant_id, id),
  constraint subcontract_line_once unique (tenant_id, order_line_id),
  constraint subcontract_line_order_line_fk foreign key (tenant_id, order_line_id)
    references erp.document_line(tenant_id, id) on delete cascade,
  constraint subcontract_line_bom_fk foreign key (tenant_id, bom_id) references erp.bom(tenant_id, id) on delete restrict
);

comment on table erp.subcontract_line is
  'A purchase order line a subcontractor makes from components sent to them (20261013110000), and the bill of '
  'materials it is made to, as it stood when the order was raised.';

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp', 'subcontract_line', 'tenant_scoped', 'A purchase order line made by a subcontractor, with the bill it is made to.')
on conflict (schema_name, table_name) do nothing;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.subcontract.components_consumed', 'en', 'Components consumed by a subcontractor', 'procurement',
   'Event raised when a product a subcontractor made is received and the components sent to them are consumed into it.'),
  ('event.subcontract.components_consumed', 'de', 'Komponenten vom Lohnfertiger verbraucht', 'procurement',
   'Ereignis, wenn ein vom Lohnfertiger hergestelltes Produkt eingeht und die beigestellten Komponenten verbraucht werden.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values ('subcontract.components_consumed', 1, 'document', 'procurement', 'event.subcontract.components_consumed',
        'A product a subcontractor made was received, and the components sent to them were consumed into it.',
        '{"type":"object","required":["receipt","consumed_minor","capitalised_minor","expensed_minor"],"properties":{"receipt":{"type":"string"},"order":{"type":"string"},"consumed_minor":{"type":"integer"},"capitalised_minor":{"type":"integer"},"expensed_minor":{"type":"integer"}}}'::jsonb,
        true)
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The order
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.raise_subcontract_order(p_supplier_party_id uuid, p_item_id uuid, p_site_id uuid,
                                                       p_quantity numeric, p_service_price_minor bigint,
                                                       p_required_date date default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  v_bom    uuid;
  v_po     uuid;
  v_line   uuid;
begin
  select s.entity_id into v_entity from erp.site s where s.tenant_id = v_tenant and s.id = p_site_id;
  if v_entity is null then
    raise exception 'CLOVEERP_UNKNOWN_SITE: % is not a site of this organisation', p_site_id
      using errcode = '23503', hint = 'Choose a site from the list.';
  end if;
  perform erp.authorise('procurement.order', v_entity, p_site_id, null, 'item', p_item_id, null);

  if not exists (select 1 from erp.party_role r
                  where r.tenant_id = v_tenant and r.party_id = p_supplier_party_id
                    and r.role_kind = 'supplier' and r.status = 'active') then
    raise exception 'CLOVEERP_SUBCONTRACTOR_NOT_A_SUPPLIER: % is not a supplier of this organisation', p_supplier_party_id
      using errcode = '23514', hint = 'Give the subcontractor a supplier role under Business partners, then raise the order.';
  end if;
  if coalesce(p_quantity, 0) <= 0 or coalesce(p_service_price_minor, 0) <= 0 then
    raise exception 'CLOVEERP_SUBCONTRACT_ORDER_INVALID: a subcontract order needs a quantity and the price of the work, each more than nought'
      using errcode = '23514', hint = 'Give how many to make and what the subcontractor charges for making one.';
  end if;

  select b.id into v_bom from erp.bom b
   where b.tenant_id = v_tenant and b.item_id = p_item_id and b.status = 'active'
     and (b.site_id is null or b.site_id = p_site_id)
   order by (b.site_id is not null) desc, b.version desc limit 1;
  if v_bom is null then
    raise exception 'CLOVEERP_NO_BILL_OF_MATERIALS: nothing says what % is made of', p_item_id
      using errcode = '23503', hint = 'Define its bill of materials, so the components to send are known.';
  end if;

  v_po := erp.open_document('purchase_order', p_supplier_party_id, v_entity, p_site_id);
  v_line := erp.add_document_line(v_po, p_item_id, p_quantity, p_service_price_minor,
                                  'Made by the subcontractor from the components sent', p_required_date);
  insert into erp.subcontract_line (tenant_id, order_line_id, bom_id) values (v_tenant, v_line, v_bom);
  return v_po;
end;
$$;
revoke all on function erp.raise_subcontract_order(uuid, uuid, uuid, numeric, bigint, date) from public, anon;

create or replace function public.erp_raise_subcontract_order(p_supplier_party_id uuid, p_item_id uuid, p_site_id uuid,
                                                              p_quantity numeric, p_service_price_minor bigint,
                                                              p_required_date date default null)
returns uuid
language sql
set search_path = ''
as $$ select erp.raise_subcontract_order(p_supplier_party_id, p_item_id, p_site_id, p_quantity, p_service_price_minor, p_required_date) $$;
revoke all on function public.erp_raise_subcontract_order(uuid, uuid, uuid, numeric, bigint, date) from public, anon;
grant execute on function public.erp_raise_subcontract_order(uuid, uuid, uuid, numeric, bigint, date) to authenticated, service_role;
comment on function public.erp_raise_subcontract_order(uuid, uuid, uuid, numeric, bigint, date) is
  'Raises a purchase order to a subcontractor for a product made to its bill of materials, at the price of the work '
  '(20261013110000). It is submitted, approved and sent as any order is. Authorises procurement.order.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The components sent
-- ─────────────────────────────────────────────────────────────────────────────

-- What one of the product takes of each component, by its bill.
create or replace function erp.subcontract_components(p_bom_id uuid)
returns table(item_id uuid, quantity_per numeric)
language sql
stable
set search_path = ''
as $$
  select bl.component_item_id,
         bl.quantity * (1 + coalesce(bl.scrap_factor, 0))
           / coalesce(nullif(b.output_quantity, 0), 1) / coalesce(nullif(b.yield_factor, 0), 1)
    from erp.bom b
    join erp.bom_line bl on bl.tenant_id = b.tenant_id and bl.bom_id = b.id and not bl.is_alternate
   where b.tenant_id = erp.require_tenant_id() and b.id = p_bom_id
$$;
revoke all on function erp.subcontract_components(uuid) from public, anon;

create or replace function erp.send_subcontract_components(p_order_line_id uuid, p_location_id uuid,
                                                           p_quantity numeric default null)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  sl       erp.subcontract_line%rowtype;
  l        erp.document_line%rowtype;
  d        erp.document%rowtype;
  v_qty    numeric;
  r        record;
  v_n      integer := 0;
begin
  select * into sl from erp.subcontract_line x where x.tenant_id = v_tenant and x.order_line_id = p_order_line_id;
  if sl.id is null then
    raise exception 'CLOVEERP_NOT_A_SUBCONTRACT_LINE: % is no line a subcontractor makes', p_order_line_id
      using errcode = '23503', hint = 'Choose a subcontract order from the list.';
  end if;
  select * into l from erp.document_line x where x.tenant_id = v_tenant and x.id = p_order_line_id;
  select * into d from erp.document x where x.tenant_id = v_tenant and x.id = l.document_id;
  perform erp.authorise('inventory.adjust', d.entity_id, d.site_id, null, 'document', d.id, null);

  v_qty := coalesce(p_quantity, greatest(l.quantity - coalesce(l.quantity_fulfilled, 0), 0));
  if v_qty <= 0 then
    raise exception 'CLOVEERP_QUANTITY_NONPOSITIVE: nothing is left on % to send components for', d.document_number
      using errcode = '23514', hint = 'Give how many of the product to send components for.';
  end if;

  for r in select c.item_id, round(c.quantity_per * v_qty, 6) as need
             from erp.subcontract_components(sl.bom_id) c
  loop
    continue when r.need <= 0;
    perform erp.hand_over_custody(r.item_id, d.site_id, p_location_id, r.need, d.party_id, null,
                                  left('sent for ' || coalesce(d.document_number, 'a subcontract order'), 64));
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke all on function erp.send_subcontract_components(uuid, uuid, numeric) from public, anon;

create or replace function public.erp_send_subcontract_components(p_order_line_id uuid, p_location_id uuid,
                                                                  p_quantity numeric default null)
returns integer
language sql
set search_path = ''
as $$ select erp.send_subcontract_components(p_order_line_id, p_location_id, p_quantity) $$;
revoke all on function public.erp_send_subcontract_components(uuid, uuid, numeric) from public, anon;
grant execute on function public.erp_send_subcontract_components(uuid, uuid, numeric) to authenticated, service_role;
comment on function public.erp_send_subcontract_components(uuid, uuid, numeric) is
  'Hands into the subcontractor''s keeping what a subcontract order line needs, by its bill of materials, from a '
  'place at its site (20261013110000). Authorises inventory.adjust.';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. Consumed as the product is received
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.consume_for_subcontract(p_receipt_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  g         erp.document%rowtype;
  rl        record;
  c         record;
  b         record;
  v_company uuid;
  v_need    numeric;
  v_held    numeric;
  v_take    numeric;
  v_unit    bigint;
  v_moved   bigint;
  v_value   bigint;
  v_landed  bigint;
  v_lines   integer := 0;
  v_parts   jsonb;
  v_ledger  uuid;
  v_inv     uuid;
  v_cos     uuid;
  v_kind    erp.account.control_kind%type;
  v_event   uuid;
  v_journal uuid;
  v_date    date;
  v_ccy     char(3);
  v_rule    uuid;
  v_version integer;
begin
  select * into g from erp.document x where x.tenant_id = v_tenant and x.id = p_receipt_id;
  if g.id is null then
    return 0;
  end if;
  v_company := erp.entity_party_for_site(g.site_id);
  v_date := coalesce(g.posting_date, g.document_date, current_date);
  select e.base_currency into v_ccy from erp.entity e where e.tenant_id = v_tenant and e.id = g.entity_id;

  for rl in
    select gl.id as receipt_line, gl.item_id, rel.quantity, sl.bom_id, od.document_number as order_number,
           od.party_id as subcontractor
      from erp.document_relation rel
      join erp.document_line gl on gl.tenant_id = rel.tenant_id and gl.id = rel.from_line_id
      join erp.subcontract_line sl on sl.tenant_id = rel.tenant_id and sl.order_line_id = rel.to_line_id
      join erp.document od on od.tenant_id = rel.tenant_id and od.id = rel.to_document_id
     where rel.tenant_id = v_tenant and rel.from_document_id = p_receipt_id and rel.relation_kind = 'fulfils'
       and coalesce(rel.quantity, 0) > 0
  loop
    v_value := 0;
    v_parts := '[]'::jsonb;
    for c in select x.item_id, round(x.quantity_per * rl.quantity, 6) as need
               from erp.subcontract_components(rl.bom_id) x
    loop
      continue when c.need <= 0;
      select coalesce(sum(sb.quantity), 0) into v_held
        from erp.stock_balance sb
       where sb.tenant_id = v_tenant and sb.site_id = g.site_id and sb.item_id = c.item_id
         and sb.custody_party_id = rl.subcontractor and sb.owner_party_id = v_company
         and sb.stock_status = 'available' and sb.quantity > 0;
      if v_held < c.need then
        raise exception 'CLOVEERP_SUBCONTRACTOR_SHORT: % made from components needs % of %, and the subcontractor holds % of it for the company',
          rl.order_number, c.need, (select i.code from erp.item i where i.id = c.item_id), v_held
          using errcode = '23514',
                hint = 'Send the subcontractor the components the order needs, then post the receipt.';
      end if;

      v_need := c.need;
      for b in
        select sb.location_id, sb.batch_id, sb.quantity
          from erp.stock_balance sb
         where sb.tenant_id = v_tenant and sb.site_id = g.site_id and sb.item_id = c.item_id
           and sb.custody_party_id = rl.subcontractor and sb.owner_party_id = v_company
           and sb.stock_status = 'available' and sb.quantity > 0
         order by sb.quantity desc, sb.location_id
      loop
        exit when v_need <= 0;
        v_take := least(v_need, b.quantity);
        v_unit := erp.issue_cost(c.item_id, g.site_id, v_take);
        insert into erp.stock_movement (
          tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
          from_location_id, from_status, quantity, uom_id, unit_cost_minor, currency, reason_code,
          owner_party_id, custody_party_id)
        values (v_tenant, g.entity_id, g.site_id, 'production_issue', c.item_id, b.batch_id,
                b.location_id, 'available', v_take,
                (select i.stock_uom_id from erp.item i where i.tenant_id = v_tenant and i.id = c.item_id),
                v_unit, coalesce(v_ccy, 'GBP'), left('made by subcontractor on ' || coalesce(rl.order_number, ''), 64),
                v_company, rl.subcontractor)
        returning id into v_moved;
        select coalesce(m.cost_minor, round(m.quantity * m.unit_cost_minor)::bigint, 0) into v_unit
          from erp.stock_movement m where m.id = v_moved;
        v_value := v_value + v_unit;
        v_parts := v_parts || jsonb_build_object('item_id', c.item_id, 'value_minor', v_unit);
        v_need := v_need - v_take;
      end loop;
    end loop;

    continue when v_value = 0;
    v_lines := v_lines + 1;

    -- The components' value onto the product received, as a landed cost
    -- lands; what cannot land is a cost of sales.
    v_landed := erp.add_freight_to_receipt_line(rl.receipt_line, v_value);

    v_event := erp.append_event('subcontract.components_consumed', 'document', p_receipt_id,
      jsonb_build_object('receipt', coalesce(g.document_number, ''), 'order', coalesce(rl.order_number, ''),
                         'consumed_minor', v_value, 'capitalised_minor', v_landed,
                         'expensed_minor', v_value - v_landed),
      g.entity_id, g.site_id);

    select lg.id into v_ledger from erp.ledger lg
     where lg.tenant_id = v_tenant and lg.entity_id = g.entity_id and lg.is_primary and lg.status = 'active';
    select a.id, a.control_kind into v_inv, v_kind from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = g.entity_id
       and a.code = erp.chart_account_code('inventory') and a.status = 'active';
    select a.id into v_cos from erp.account a where a.tenant_id = v_tenant and a.entity_id = g.entity_id
       and a.code = erp.chart_account_code('cost_of_sales') and a.status = 'active';
    if v_ledger is null or v_inv is null or v_cos is null then
      raise exception 'CLOVEERP_ACCOUNT_NOT_ON_CHART: % lacks inventory or cost of sales to consume components into',
        coalesce((select e.code from erp.entity e where e.id = g.entity_id), 'the company')
        using errcode = '23514', hint = 'Upgrade finance, which installs inventory and cost of sales.';
    end if;

    -- Traced to the rule that posted the receipt, as a landed cost is traced
    -- to its bill's.
    select jl.posting_rule_id, jl.posting_rule_version into v_rule, v_version
      from erp.journal j join erp.journal_line jl on jl.journal_id = j.id
     where j.tenant_id = v_tenant and j.document_id = p_receipt_id and jl.posting_rule_id is not null
     order by jl.line_no limit 1;

    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, source_event_id, posting_date,
                             description, status, document_id)
    values (v_tenant, g.entity_id, v_ledger, 'subcontract.components_consumed', v_event, v_date,
            format('Components made into %s by the subcontractor, received on %s', coalesce(rl.order_number, 'an order'),
                   coalesce(g.document_number, 'a receipt')),
            'draft', p_receipt_id)
    returning id into v_journal;

    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                  base_debit_minor, base_credit_minor, exchange_rate, posting_rule_id, posting_rule_version,
                                  source_event_id, description)
    values (v_tenant, v_journal, 1, v_inv, 0, v_value, coalesce(v_ccy, 'GBP'), 0, v_value, 1, v_rule, v_version, v_event,
            'Components out of stock, consumed by the subcontractor');
    if v_landed > 0 then
      insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                    base_debit_minor, base_credit_minor, exchange_rate, posting_rule_id, posting_rule_version,
                                    source_event_id, description)
      values (v_tenant, v_journal, 2, v_inv, v_landed, 0, coalesce(v_ccy, 'GBP'), v_landed, 0, 1, v_rule, v_version, v_event,
              'Their value, onto the product made from them');
    end if;
    if v_value - v_landed > 0 then
      insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                    base_debit_minor, base_credit_minor, exchange_rate, posting_rule_id, posting_rule_version,
                                    source_event_id, description)
      values (v_tenant, v_journal, 3, v_cos, v_value - v_landed, 0, coalesce(v_ccy, 'GBP'), v_value - v_landed, 0, 1,
              v_rule, v_version, v_event, 'What could not land on the product, which is gone or carried at standard');
    end if;

    -- The inventory control carries its detail by item, as every stock
    -- posting does: each component out, the product in.
    if v_kind is not null then
      insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                      item_id, journal_id, currency, debit_minor, credit_minor, posting_date)
      select v_tenant, g.entity_id, v_ledger, v_kind, v_inv, (x ->> 'item_id')::uuid, v_journal, coalesce(v_ccy, 'GBP'),
             0, sum((x ->> 'value_minor')::bigint), v_date
        from jsonb_array_elements(v_parts) x
       group by (x ->> 'item_id')::uuid;
      if v_landed > 0 then
        insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                        item_id, journal_id, currency, debit_minor, credit_minor, posting_date)
        values (v_tenant, g.entity_id, v_ledger, v_kind, v_inv, rl.item_id, v_journal, coalesce(v_ccy, 'GBP'),
                v_landed, 0, v_date);
      end if;
    end if;

    update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
     where id = v_journal;
  end loop;

  return v_lines;
end;
$$;
revoke all on function erp.consume_for_subcontract(uuid) from public, anon;

do $receive$
declare
  v_sig  constant text := 'erp.transition_document(uuid,text,text)';
  v_def  text;
  v_old  constant text := $o$    perform erp.arrive_inbound_shipments(p_document_id);
  end if;$o$;
  v_new  constant text := $n$    perform erp.arrive_inbound_shipments(p_document_id);
    -- And what a subcontractor made it from is consumed into it (20261013110000).
    perform erp.consume_for_subcontract(p_document_id);
  end if;$n$;
  v_hits integer;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'erp' and p.proname = 'transition_document';
  if position('20261013110000' in v_def) > 0 then
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % receipt anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$receive$;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The list
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_subcontract_orders()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'order_line_id', l.id, 'document_id', d.id, 'order_number', coalesce(d.document_number, 'draft'),
           'subcontractor', p.name, 'item', i.code, 'item_name', i.name,
           'quantity', l.quantity, 'received', coalesce(l.quantity_fulfilled, 0),
           'price_minor', l.unit_price_minor,
           'state', coalesce(erp.object_current_state('document', d.id), 'draft'),
           'components_held', (select string_agg(ci.code || ' × ' || trim(to_char(h.held, 'FM9999999990.######')), ', ' order by ci.code)
                                 from (select sb.item_id, sum(sb.quantity) as held
                                         from erp.stock_balance sb
                                        where sb.tenant_id = d.tenant_id and sb.site_id = d.site_id
                                          and sb.custody_party_id = d.party_id and sb.quantity > 0
                                          and sb.item_id in (select c.item_id from erp.subcontract_components(sl.bom_id) c)
                                        group by sb.item_id) h
                                 join erp.item ci on ci.tenant_id = d.tenant_id and ci.id = h.item_id))
           order by d.created_at desc), '[]'::jsonb)
    from erp.subcontract_line sl
    join erp.document_line l on l.tenant_id = sl.tenant_id and l.id = sl.order_line_id
    join erp.document d on d.tenant_id = l.tenant_id and d.id = l.document_id
    join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
    join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
   where sl.tenant_id = erp.require_tenant_id() and not l.is_cancelled
$$;
revoke all on function public.erp_subcontract_orders() from public, anon;
grant execute on function public.erp_subcontract_orders() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- Governance
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_raise_subcontract_order', 'erp.raise_subcontract_order',
   'Raises a purchase order to a subcontractor for a product made to its bill; authorises procurement.order.'),
  ('erp_send_subcontract_components', 'erp.send_subcontract_components',
   'Hands into a subcontractor''s keeping the components an order needs; authorises inventory.adjust.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp.register_refusal('CLOVEERP_SUBCONTRACTOR_NOT_A_SUPPLIER',
  'Raising a subcontract order to a party the organisation does not buy from.',
  'The subcontractor is paid as a supplier is: their bill, the payment run and the ledger read them as one.',
  'Give the subcontractor a supplier role under Business partners, then raise the order.');
select erp.register_refusal('CLOVEERP_SUBCONTRACT_ORDER_INVALID',
  'Raising a subcontract order for nothing, or at no price for the work.',
  'The order says how many to make and what making one costs; the product is valued at that and its components.',
  'Give how many to make and what the subcontractor charges for making one.');
select erp.register_refusal('CLOVEERP_NOT_A_SUBCONTRACT_LINE',
  'Sending components for an order line no subcontractor makes.',
  'Only a line raised as a subcontract order says which components it is made from.',
  'Choose a subcontract order from the list.');
select erp.register_refusal('CLOVEERP_SUBCONTRACTOR_SHORT',
  'Posting a receipt of a product a subcontractor made when they hold too few of its components.',
  'The product is valued at the work and its components; taking it in without them would value it at less than it cost.',
  'Send the subcontractor the components the order needs, then post the receipt.');

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Subcontracting (20261013110000).'
  from (values
    ('Components held'),
    ('Order from a subcontractor'),
    ('Price of the work, each'),
    ('Send components to a subcontractor'),
    ('Subcontract orders'),
    ('Subcontractor'),
    ('What a subcontractor charges for making one. The product is valued at this and the components sent.'),
    ('A purchase order to a subcontractor for a product made to its bill of materials, at the price of the work. Submit, approve and send it as any order; send them the components; receiving it consumes the components into the product.'),
    ('Hands the components a subcontract order needs, by its bill of materials, into the subcontractor''s keeping.'),
    ('How many of the product to send components for. Leave empty for what is left on the order.'),
    ('Orders a subcontractor makes from components sent to them: what has come back, and what they still hold.'),
    ('No subcontract orders yet. Raise one from Actions for a product with a bill of materials.')) v(text)
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.subcontract_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_entity uuid;
  v_site   uuid;
  v_loc    uuid;
  v_uom    uuid;
  v_sub    uuid;
  v_other  uuid;
  v_frame  uuid;
  v_steel  uuid;
  v_grn    uuid;
  v_po     uuid;
  v_po2    uuid;
  v_line   uuid;
  x        jsonb;
  v_ok     boolean;
  v_msg    text;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzsub' || v_tag, 'Subcontract Suite',
      'admin@demo-zzsub' || v_tag || '.test', 'Subcontract Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzsub' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;

    v_step := 'a frame a subcontractor welds from two steel bars';
    select s.id, s.entity_id into v_site, v_entity from erp.site s where s.tenant_id = v_tenant and s.status = 'active'
     order by (s.site_type = 'warehouse') desc, s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = v_tenant order by u.code limit 1;
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (v_tenant, 'ZSUB' || upper(v_tag), 'Welders Ltd', 'GB', 'active') returning id into v_sub;
    insert into erp.party_role (tenant_id, party_id, role_kind, status) values (v_tenant, v_sub, 'supplier', 'active');
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (v_tenant, 'ZCUS' || upper(v_tag), 'Not A Supplier', 'GB', 'active') returning id into v_other;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (v_tenant, 'ZSUBFR' || v_tag, 'Welded frame', v_uom, 'active') returning id into v_frame;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (v_tenant, 'ZSUBST' || v_tag, 'Steel bar', v_uom, 'active') returning id into v_steel;
    perform public.erp_create_bom(v_frame, null, null, 1, null,
      jsonb_build_array(jsonb_build_object('component_item_id', v_steel, 'quantity', 2)));
    -- Twenty steel bars at £1 each.
    v_grn := erp.open_document('goods_receipt', v_sub, null, v_site);
    perform erp.add_document_line(v_grn, v_steel, 20, 100, 'steel');
    perform erp.transition_document(v_grn, 'post');
    select m.to_location_id into v_loc from erp.stock_movement m
     where m.tenant_id = v_tenant and m.document_id = v_grn limit 1;

    -- ── 1. The order ────────────────────────────────────────────────────────
    v_step := 'the subcontract order';
    begin
      perform public.erp_raise_subcontract_order(v_other, v_frame, v_site, 5, 300);
      v_ok := false; v_msg := 'ordered from a party that is no supplier';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_SUBCONTRACTOR_NOT_A_SUPPLIER%'; v_msg := left(sqlerrm, 80);
    end;
    -- Five frames at £3 of welding each.
    v_po := public.erp_raise_subcontract_order(v_sub, v_frame, v_site, 5, 300);
    select l.id into v_line from erp.document_line l where l.document_id = v_po;
    v_cases := v_cases + 1;
    case_name := 'a subcontract order is a purchase order for the product at the price of the work, made to its bill';
    passed := v_state is null and v_ok
          and (select l.unit_price_minor from erp.document_line l where l.id = v_line) = 300
          and exists (select 1 from erp.subcontract_line sl where sl.order_line_id = v_line);
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 2. The components sent ──────────────────────────────────────────────
    v_step := 'the steel sent';
    perform public.erp_send_subcontract_components(v_line, v_loc);
    x := public.erp_stock_with_keepers();
    v_cases := v_cases + 1;
    case_name := 'the ten bars the order needs go into the subcontractor''s keeping, and are listed as with them';
    passed := v_state is null
          and exists (select 1 from jsonb_array_elements(x) k
                       where k ->> 'item' = 'ZSUBST' || v_tag and k ->> 'keeper' = 'Welders Ltd' and (k ->> 'quantity')::numeric = 10)
          and (public.erp_subcontract_orders() -> 0 ->> 'components_held') = 'ZSUBST' || v_tag || ' × 10';
    detail := coalesce(v_state, left(x::text, 200));
    return next;

    -- ── 3. The frames received ──────────────────────────────────────────────
    v_step := 'the frames received';
    perform erp.transition_document(v_po, 'submit', null);
    if erp.object_current_state('document', v_po) <> 'approved' then
      perform erp_test.approve_document(v_po, 'fixture');
    end if;
    perform erp.transition_document(v_po, 'send', null);
    x := erp.create_receipt_from_order(v_po, null, 'post');
    v_cases := v_cases + 1;
    -- £15 of welding and £10 of steel: £5 a frame.
    case_name := 'received, the frames cost the welding and the steel, £5 each, and the subcontractor holds no steel';
    passed := v_state is null
          and erp.item_stock_value(v_frame, v_site) = 2500
          and not exists (select 1 from erp.stock_balance sb
                           where sb.tenant_id = v_tenant and sb.item_id = v_steel and sb.custody_party_id = v_sub
                             and sb.quantity > 0);
    detail := coalesce(v_state, format('frames worth %s', erp.item_stock_value(v_frame, v_site)));
    return next;

    -- ── 4. The books ────────────────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'one journal moves the steel''s £10 out of stock and onto the frames, and nothing to cost of sales';
    passed := v_state is null
          and (select count(*) from erp.journal j
                where j.tenant_id = v_tenant and j.source_code = 'subcontract.components_consumed' and j.status = 'posted') = 1
          and (select sum(jl.credit_minor) - sum(jl.debit_minor) from erp.journal_line jl
                 join erp.journal j on j.id = jl.journal_id
                 join erp.account a on a.id = jl.account_id
                where j.tenant_id = v_tenant and j.source_code = 'subcontract.components_consumed'
                  and a.code = erp.chart_account_code('inventory')) = 0
          and (select count(*) from erp.journal_line jl join erp.journal j on j.id = jl.journal_id
                where j.tenant_id = v_tenant and j.source_code = 'subcontract.components_consumed') = 2;
    detail := coalesce(v_state, (select string_agg(format('%s %s/%s', a.code, jl.debit_minor, jl.credit_minor), ', ')
                                   from erp.journal_line jl join erp.journal j on j.id = jl.journal_id
                                   join erp.account a on a.id = jl.account_id
                                  where j.tenant_id = v_tenant and j.source_code = 'subcontract.components_consumed'));
    return next;

    -- ── 5. Not without the components ───────────────────────────────────────
    v_step := 'a second order, with nothing sent';
    v_po2 := public.erp_raise_subcontract_order(v_sub, v_frame, v_site, 5, 300);
    perform erp.transition_document(v_po2, 'submit', null);
    if erp.object_current_state('document', v_po2) <> 'approved' then
      perform erp_test.approve_document(v_po2, 'fixture');
    end if;
    perform erp.transition_document(v_po2, 'send', null);
    begin
      perform erp.create_receipt_from_order(v_po2, null, 'post');
      v_ok := false; v_msg := 'received with no steel sent';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_SUBCONTRACTOR_SHORT%'; v_msg := left(sqlerrm, 120);
    end;
    v_cases := v_cases + 1;
    case_name := 'a receipt the components sent do not cover is refused, and the frames stay out of stock';
    passed := v_state is null and v_ok and erp.item_stock_value(v_frame, v_site) = 2500;
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 6. The list ─────────────────────────────────────────────────────────
    x := public.erp_subcontract_orders();
    v_cases := v_cases + 1;
    case_name := 'the subcontract orders are listed with what has come back';
    passed := v_state is null
          and jsonb_array_length(x) = 2
          and exists (select 1 from jsonb_array_elements(x) o
                       where o ->> 'order_line_id' = v_line::text and (o ->> 'received')::numeric = 5);
    detail := coalesce(v_state, left(x::text, 200));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_SUBCONTRACT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.subcontract_suite() from public, anon, authenticated;

create or replace function erp_test.assert_subcontract_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _subcontract on commit drop as
    select * from erp_test.subcontract_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _subcontract;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_SUBCONTRACT_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_SUBCONTRACT_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('subcontracting: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_subcontract_suite() from public, anon, authenticated;

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
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
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
select erp.assert_write_only_columns();
