-- Stock-aware outbound source resolution.
create or replace function erp.default_posting_location(
  p_site_id   uuid,
  p_direction erp.movement_direction,
  p_item_id   uuid,
  p_batch_id  uuid default null,
  p_quantity  numeric default 0
) returns uuid
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
begin
  -- Inbound and transfers keep the configured bay: goods arrive where the site
  -- says they arrive.
  if p_direction <> 'out'::erp.movement_direction then
    return erp.default_posting_location(p_site_id, p_direction);
  end if;

  -- Outbound comes from wherever the stock actually stands. Picking the
  -- despatch bay blindly makes every despatch fail on a site that puts stock
  -- away properly, which is every site.
  select sb.location_id into v_id
    from erp.stock_balance sb
    join erp.location l
      on l.tenant_id = sb.tenant_id and l.id = sb.location_id
   where sb.tenant_id = v_tenant
     and sb.site_id = p_site_id
     and sb.item_id = p_item_id
     and coalesce(sb.batch_id, '00000000-0000-0000-0000-000000000000'::uuid)
         = coalesce(p_batch_id, '00000000-0000-0000-0000-000000000000'::uuid)
     and sb.stock_status = 'available'::erp.stock_status
     and sb.quantity >= greatest(p_quantity, 0)
     and sb.quantity > 0
     and l.status = 'active'::erp.record_status
     and not l.is_blocked
     and l.location_type <> 'quarantine'::erp.location_type
   order by case when coalesce(l.is_pickable, false) then 0 else 1 end,
            case when l.location_type = 'despatch'::erp.location_type then 0 else 1 end,
            sb.quantity desc,
            l.code
   limit 1;

  if v_id is not null then
    return v_id;
  end if;

  -- Nothing holds enough: fall back to the configured despatch bay so the
  -- ledger raises its own negative-stock refusal, with its own wording.
  return erp.default_posting_location(p_site_id, p_direction);
end;
$$;

comment on function erp.default_posting_location(uuid, erp.movement_direction, uuid, uuid, numeric) is
  'Where a posting line moves stock from or to. Outbound resolves against the '
  'balances so a despatch draws from the location actually holding the goods; '
  'inbound keeps the site''s configured receiving bay.';

revoke all on function erp.default_posting_location(uuid, erp.movement_direction, uuid, uuid, numeric)
  from public, anon, authenticated;

-- Repost the stock side of a document through the stock-aware resolver.
create or replace function erp.post_document_stock(p_document_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  d          erp.document%rowtype;
  dt         erp.document_type%rowtype;
  bt         erp_ref.document_type%rowtype;
  mt         erp_ref.movement_type%rowtype;
  ln         record;
  v_location uuid;
  v_cost     bigint;
  v_count    integer := 0;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select * into dt from erp.document_type
   where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;

  if not bt.affects_stock then
    return 0;
  end if;

  if exists (select 1 from erp.stock_movement m
              where m.tenant_id = v_tenant and m.document_id = p_document_id) then
    raise exception
      'ERPWARE_ALREADY_POSTED: % has already moved stock; reverse it rather '
      'than posting again', d.document_number
      using errcode = '23505';
  end if;

  if dt.stock_movement_type is null then
    raise exception
      'ERPWARE_NO_MOVEMENT_TYPE: % moves stock but names no movement type',
      dt.code
      using errcode = '23502',
      detail = 'erp_ref.document_type.affects_stock is true for base type '
               || dt.base_type_code;
  end if;

  select * into mt from erp_ref.movement_type where code = dt.stock_movement_type;

  if d.site_id is null then
    raise exception 'ERPWARE_NO_SITE: % moves stock but names no site', d.document_number
      using errcode = '23502';
  end if;

  perform erp.authorise(
    case when mt.direction = 'in' then 'procurement.receive' else 'sales.despatch' end,
    d.entity_id, d.site_id, null, 'document', p_document_id);

  for ln in
    select l.* from erp.document_line l
     where l.tenant_id = v_tenant and l.document_id = p_document_id
       and not l.is_cancelled and l.quantity > 0
     order by l.line_no
  loop
    v_location := coalesce(
      ln.location_id,
      erp.default_posting_location(d.site_id, mt.direction, ln.item_id, ln.batch_id, ln.quantity));

    if mt.direction = 'in' then
      v_cost := erp.receive_cost(
        ln.item_id, d.site_id, ln.quantity,
        coalesce(ln.unit_price_minor, 0), coalesce(ln.currency, d.currency),
        ln.batch_id, null);
    elsif mt.direction = 'out' then
      v_cost := erp.issue_cost(ln.item_id, d.site_id, ln.quantity);
    else
      v_cost := coalesce(ln.unit_price_minor, 0);
    end if;

    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id,
      batch_id, serial_id, container_id,
      from_location_id, from_status, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency,
      document_id, document_line_id)
    values (
      v_tenant, d.entity_id, d.site_id, mt.code, ln.item_id,
      ln.batch_id, ln.serial_id, ln.container_id,
      case when mt.direction in ('out', 'transfer') then v_location end,
      case when mt.direction in ('out', 'transfer') then 'available'::erp.stock_status end,
      case when mt.direction in ('in',  'transfer') then v_location end,
      case when mt.direction in ('in', 'transfer') then
        case when mt.direction = 'in'
                  and (select i.quarantine_on_receipt from erp.item i
                        where i.id = ln.item_id)
             then 'quarantine'::erp.stock_status
             else 'available'::erp.stock_status end
      end,
      ln.quantity,
      coalesce(ln.uom_id, (select i.stock_uom_id from erp.item i where i.id = ln.item_id)),
      v_cost, coalesce(ln.currency, d.currency),
      p_document_id, ln.id);

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- Standard locations for new sites carry honest picking flags.
update erp.location
   set is_pickable = false
 where location_type in ('receiving'::erp.location_type,
                         'quarantine'::erp.location_type,
                         'despatch'::erp.location_type)
   and is_pickable;
