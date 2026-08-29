-- =============================================================================
-- ERPWare — making a posted document actually move stock
--
-- erp.stock_movement is written in exactly two places in this repository: B7's
-- own migration, and B7's test suite. No module posts stock. Procurement's
-- goods receipt has a draft → posted transition that moves the document's state
-- and touches nothing else — no movement, no balance, no journal.
--
-- That was in the plan for procurement and did not get built. It was dropped
-- when transition effects turned out never to be executed, and shipping a
-- receipt that looks like it does something was the wrong answer: an inert
-- posting is the same failure as dead configuration, one layer up.
--
-- The bridge is one function serving both directions, and that is the point.
-- Product content already carries the whole vocabulary:
--
--   erp_ref.document_type    declares whether a type affects stock, and its flow
--   erp_ref.movement_type    seeds goods_receipt (in), despatch (out), pick,
--                            return_from_customer, return_to_supplier — each
--                            carrying its own direction
--
-- What was missing is the link between them: which movement a document type's
-- posting raises. That is a tenant's choice, so it belongs on erp.document_type
-- rather than in product content, which only says whether stock moves at all.
--
-- Direction then comes from erp_ref.movement_type.direction and never from a
-- module name. That is what lets procurement's receipt and sales' delivery be
-- the same code path with opposite signs, rather than two implementations that
-- drift.
-- =============================================================================

alter table erp.document_type
  add column if not exists stock_movement_type text
    references erp_ref.movement_type(code);

comment on column erp.document_type.stock_movement_type is
  'Which movement posting this document type raises. Product content says '
  'whether stock moves; this says which movement it is. Required wherever the '
  'base type declares affects_stock — erp.assert_no_dead_configuration() '
  'fails the build otherwise.';

-- -----------------------------------------------------------------------------
-- Where does the stock land, or leave from?
--
-- B7's ledger trigger decides sides by from_location_id and to_location_id
-- rather than by the movement type, so posting has to name a location. A line
-- may carry its own; otherwise the site's location of the matching type is the
-- sensible default, and no default at all is a refusal rather than a guess.
-- -----------------------------------------------------------------------------

create or replace function erp.default_posting_location(
  p_site_id   uuid,
  p_direction erp.movement_direction
) returns uuid
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_kind   erp.location_type;
  v_id     uuid;
begin
  v_kind := case p_direction
              when 'in'  then 'receiving'::erp.location_type
              when 'out' then 'despatch'::erp.location_type
              else 'staging'::erp.location_type
            end;

  select l.id into v_id
    from erp.location l
   where l.tenant_id = v_tenant
     and l.site_id = p_site_id
     and l.location_type = v_kind
     and l.status = 'active'
     and not l.is_blocked
   order by l.code
   limit 1;

  if v_id is null then
    raise exception
      'ERPWARE_NO_POSTING_LOCATION: site has no active % location, so a % '
      'movement has nowhere to go', v_kind, p_direction
      using errcode = '23503',
      hint = 'Give the line an explicit location, or configure one of this type.';
  end if;

  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Posting
-- -----------------------------------------------------------------------------

create or replace function erp.post_document(p_document_id uuid)
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
  v_count    integer := 0;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select * into dt from erp.document_type
   where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;

  -- Nothing to do is not an error: most document types move no stock, and the
  -- caller should not have to know which.
  if not bt.affects_stock then
    return 0;
  end if;

  -- Posting twice would double the stock. The ledger is append-only, so there
  -- is no undoing it — a receipt is corrected by reversing it, never by
  -- posting it again.
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
    v_location := coalesce(ln.location_id,
                           erp.default_posting_location(d.site_id, mt.direction));

    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id,
      batch_id, serial_id, container_id,
      -- One expression, both directions. B7's trigger reads these to decide
      -- which side of the balance to touch, so 'in' fills the destination and
      -- 'out' fills the source; a transfer would fill both.
      from_location_id, from_status, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency,
      document_id, document_line_id)
    values (
      v_tenant, d.entity_id, d.site_id, mt.code, ln.item_id,
      ln.batch_id, ln.serial_id, ln.container_id,
      case when mt.direction in ('out', 'transfer') then v_location end,
      case when mt.direction in ('out', 'transfer') then 'available'::erp.stock_status end,
      case when mt.direction in ('in',  'transfer') then v_location end,
      case when mt.direction in ('in',  'transfer') then 'available'::erp.stock_status end,
      ln.quantity,
      coalesce(ln.uom_id, (select i.stock_uom_id from erp.item i where i.id = ln.item_id)),
      ln.unit_price_minor, coalesce(ln.currency, d.currency),
      p_document_id, ln.id);

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

comment on function erp.post_document(uuid) is
  'Turns a posted document into ledger movements. One function for both '
  'directions: the sign comes from erp_ref.movement_type.direction, never from '
  'which module raised the document.';

-- -----------------------------------------------------------------------------
-- Posting is a property of the lifecycle, not a second API
--
-- A caller that has to remember to post after transitioning is a caller that
-- will forget. Committing a document is what posts it, and the state machine
-- already says which states are committed.
-- -----------------------------------------------------------------------------

create or replace function erp.transition_document(
  p_document_id    uuid,
  p_transition_code text,
  p_reason         text default null
) returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  bt       erp_ref.document_type%rowtype;
  v_ctx    jsonb;
  v_to     text;
  v_committed boolean;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select * into dt from erp.document_type where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;

  v_ctx := jsonb_build_object(
    'document_type', dt.code,
    'document_number', d.document_number,
    'total_minor', erp.document_value_minor(p_document_id),
    'currency', d.currency,
    'party_id', d.party_id,
    'entity_id', d.entity_id,
    'transition', p_transition_code);

  if p_transition_code = 'submit' and dt.approval_chain_code is not null then
    perform erp.request_approval('document', p_document_id, v_ctx, 1,
                                 d.entity_id, d.site_id);
  end if;

  v_to := erp.perform_transition('document', p_document_id, p_transition_code,
                                 v_ctx, p_reason);

  -- Committed means the outside world now believes this. For a type that moves
  -- stock, that is exactly the moment the ledger has to agree.
  select s.is_committed into v_committed
    from erp.object_state os
    join erp.state s on s.id = os.current_state_id
   where os.tenant_id = v_tenant and os.object_type = 'document'
     and os.object_id = p_document_id;

  if coalesce(v_committed, false) and bt.affects_stock
     and not exists (select 1 from erp.stock_movement m
                      where m.tenant_id = v_tenant and m.document_id = p_document_id)
  then
    perform erp.post_document(p_document_id);
  end if;

  return v_to;
end;
$$;

-- -----------------------------------------------------------------------------
-- The assertion that keeps the link honest
-- -----------------------------------------------------------------------------

create or replace function erp.dead_configuration_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  select 'a transition declares effects that nothing executes',
         format('%s.%s', m.code, t.code),
         'erp.perform_transition() does not run transition effects, so this '
         'configuration would be stored and silently ignored'
    from erp.transition t
    join erp.state_machine_version v on v.id = t.state_machine_version_id
    join erp.state_machine m on m.id = v.state_machine_id
   where jsonb_array_length(coalesce(t.effects, '[]'::jsonb)) > 0
  union all
  select 'a state declares entry or exit actions that nothing executes',
         format('%s.%s', m.code, s.code),
         'on_enter and on_exit are stored and never read'
    from erp.state s
    join erp.state_machine_version v on v.id = s.state_machine_version_id
    join erp.state_machine m on m.id = v.state_machine_id
   where jsonb_array_length(coalesce(s.on_enter, '[]'::jsonb)) > 0
      or jsonb_array_length(coalesce(s.on_exit, '[]'::jsonb)) > 0
  union all
  select 'a document type names a state machine that does not exist',
         dt.code, format('state_machine_code = %s', dt.state_machine_code)
    from erp.document_type dt
   where dt.status = 'active'
     and dt.state_machine_code is not null
     and not exists (
       select 1 from erp.state_machine m
        where m.tenant_id = dt.tenant_id and m.code = dt.state_machine_code
          and m.status = 'active')
  union all
  -- The new one. A type whose base declares affects_stock but which names no
  -- movement would commit, look posted, and move nothing — which is exactly
  -- the state procurement's goods receipt shipped in.
  select 'a document type moves stock but names no movement type',
         dt.code,
         format('base type %s declares affects_stock', dt.base_type_code)
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.status = 'active'
     and bt.affects_stock
     and dt.stock_movement_type is null
  union all
  -- And the reverse: a movement bound to a type that does not move stock would
  -- never fire, which reads as configured behaviour and is not.
  select 'a document type names a movement type but moves no stock',
         dt.code,
         format('stock_movement_type = %s, but base type %s declares '
                'affects_stock false', dt.stock_movement_type, dt.base_type_code)
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.status = 'active'
     and not bt.affects_stock
     and dt.stock_movement_type is not null
$$;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_no_dead_configuration();
select erp.assert_public_api_safe();
select erp.assert_isolation();
