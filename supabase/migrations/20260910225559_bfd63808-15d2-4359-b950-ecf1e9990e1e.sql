-- A requisition that has been approved is not an order yet. Someone decides to
-- place it. This is that decision, made once, with the lines carried across and
-- the link back kept, so a part conversion can be finished later.

create or replace function erp.convert_document(
  p_document_id uuid,
  p_party_id    uuid    default null,
  p_site_id     uuid    default null,
  p_lines       jsonb   default null,
  p_transition  text    default null
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  d          erp.document%rowtype;
  v_base     text;
  v_target   text;
  v_type     text;
  bt         erp_ref.document_type%rowtype;
  v_state    text;
  v_party    uuid;
  v_site     uuid;
  v_new      uuid;
  v_newline  uuid;
  v_added    integer := 0;
  v_qty      numeric;
  v_out      numeric;
  l          record;
  sel        jsonb;
  v_left     numeric;
  v_moved    text := null;
  v_source   text := null;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: no such document'
      using errcode = '23503', hint = 'Choose a document from the list.';
  end if;

  if d.is_cancelled then
    raise exception 'CLOVEERP_DOCUMENT_CANCELLED: % is cancelled', d.document_number
      using errcode = '23514', hint = 'A cancelled document cannot be converted.';
  end if;

  select bt2.code into v_base
    from erp.document_type dt
    join erp_ref.document_type bt2 on bt2.code = dt.base_type_code
   where dt.tenant_id = v_tenant and dt.id = d.document_type_id;

  v_target := case v_base
                when 'requisition' then 'purchase_order'
                when 'quotation'   then 'sales_order'
                else null end;

  if v_target is null then
    raise exception 'CLOVEERP_NOTHING_TO_CONVERT_TO: % does not convert', coalesce(v_base, 'this document')
      using errcode = '23514',
      hint = 'Only an approved requisition or an accepted quotation converts into an order.';
  end if;

  v_state := erp.object_current_state('document', p_document_id);

  if v_base = 'requisition' and coalesce(v_state, '') not in ('approved') then
    raise exception 'CLOVEERP_NOT_APPROVED_YET: % is %', d.document_number, coalesce(v_state, 'draft')
      using errcode = '23514',
      hint = 'A requisition becomes an order once it has been approved.';
  end if;

  if v_base = 'quotation' and coalesce(v_state, '') not in ('accepted', 'sent') then
    raise exception 'CLOVEERP_NOT_ACCEPTED_YET: % is %', d.document_number, coalesce(v_state, 'draft')
      using errcode = '23514',
      hint = 'Send the quotation and record the customer''s acceptance first.';
  end if;

  select dt.code into v_type
    from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.base_type_code = v_target and dt.status = 'active'
   order by dt.code
   limit 1;

  if v_type is null then
    raise exception 'CLOVEERP_NO_TARGET_TYPE: this organisation has no % type', v_target
      using errcode = '23503',
      hint = 'Add the document type in Settings before converting.';
  end if;

  select * into bt from erp_ref.document_type where code = v_target;

  v_party := coalesce(p_party_id, d.party_id);
  v_site  := coalesce(p_site_id, d.site_id);

  if bt.requires_party and v_party is null then
    raise exception 'CLOVEERP_CONVERT_NEEDS_PARTY: the new order needs a trading party'
      using errcode = '23502',
      hint = 'Choose the supplier or customer the order goes to.';
  end if;

  if bt.requires_site and v_site is null then
    raise exception 'CLOVEERP_CONVERT_NEEDS_SITE: the new order needs a site'
      using errcode = '23502',
      hint = 'Choose the site the goods are for.';
  end if;

  v_new := erp.open_document(v_type, v_party, null, v_site,
                             d.their_reference, d.required_date, d.currency);

  for l in
    select dl.*,
           dl.quantity - coalesce((
             select sum(r.quantity) from erp.document_relation r
              where r.tenant_id = v_tenant
                and r.relation_kind = 'converts'
                and r.to_line_id = dl.id), 0) as outstanding
      from erp.document_line dl
     where dl.tenant_id = v_tenant
       and dl.document_id = p_document_id
       and not dl.is_cancelled
     order by dl.line_no
  loop
    v_out := coalesce(l.outstanding, 0);

    if p_lines is null then
      v_qty := v_out;
    else
      select e into sel
        from jsonb_array_elements(p_lines) e
       where e->>'line_id' = l.id::text
       limit 1;
      if sel is null then
        continue;
      end if;
      v_qty := coalesce(nullif(sel->>'quantity', '')::numeric, v_out);
      sel := null;
    end if;

    if v_qty is null or v_qty <= 0 then
      continue;
    end if;

    if v_qty > v_out then
      raise exception 'CLOVEERP_MORE_THAN_OUTSTANDING: line % has only % left to convert', l.line_no, v_out
        using errcode = '23514',
        hint = 'Convert what is outstanding, or less.';
    end if;

    perform erp.add_document_line(v_new, l.item_id, v_qty,
                                  coalesce(l.unit_price_minor, 0),
                                  l.description, l.required_date);

    select dl.id into v_newline
      from erp.document_line dl
     where dl.tenant_id = v_tenant and dl.document_id = v_new
     order by dl.line_no desc
     limit 1;

    insert into erp.document_relation (
      tenant_id, from_document_id, to_document_id, relation_kind,
      from_line_id, to_line_id, quantity)
    values (v_tenant, v_new, p_document_id, 'converts', v_newline, l.id, v_qty);

    v_added := v_added + 1;
  end loop;

  if v_added = 0 then
    raise exception 'CLOVEERP_NOTHING_OUTSTANDING: % has nothing left to convert', d.document_number
      using errcode = '23514',
      hint = 'Every line has already been ordered, or no line was chosen.';
  end if;

  -- What is left on the source, once this conversion is counted.
  select coalesce(sum(dl.quantity - coalesce((
           select sum(r.quantity) from erp.document_relation r
            where r.tenant_id = v_tenant
              and r.relation_kind = 'converts'
              and r.to_line_id = dl.id), 0)), 0)
    into v_left
    from erp.document_line dl
   where dl.tenant_id = v_tenant and dl.document_id = p_document_id and not dl.is_cancelled;

  -- Fully converted, so the source says so — if its own rules allow the move.
  if v_left <= 0 then
    select at.transition_code into v_source
      from erp.available_transitions('document', p_document_id,
             erp.document_transition_context(p_document_id, null)) at
     where at.guard_passes and at.permitted and at.to_state in ('ordered', 'accepted')
     limit 1;

    if v_source is not null then
      perform erp.transition_document(p_document_id, v_source, 'Converted into an order');
    end if;
  end if;

  if coalesce(p_transition, '') <> '' then
    if p_transition = 'auto' then
      select at.transition_code into v_moved
        from erp.available_transitions('document', v_new,
               erp.document_transition_context(v_new, null)) at
       where at.guard_passes and at.permitted and not at.is_automatic
       limit 1;
    else
      v_moved := p_transition;
    end if;

    if v_moved is not null then
      perform erp.transition_document(v_new, v_moved, 'Created by conversion');
    end if;
  end if;

  return jsonb_build_object(
    'document_id', v_new,
    'document_number', (select dn.document_number from erp.document dn
                         where dn.tenant_id = v_tenant and dn.id = v_new),
    'source_document_number', d.document_number,
    'lines', v_added,
    'outstanding_on_source', v_left,
    'source_moved_on', v_source,
    'moved_on', v_moved);
end;
$$;

comment on function erp.convert_document(uuid, uuid, uuid, jsonb, text)
  is 'Turns an approved requisition into a purchase order, or an accepted quotation into a sales order, line by line, keeping the link back.';

create or replace function public.erp_convert_document(
  p_document_id uuid,
  p_party_id    uuid    default null,
  p_site_id     uuid    default null,
  p_lines       jsonb   default null,
  p_transition  text    default null
) returns jsonb
language sql
set search_path = ''
as $$
  select erp.convert_document(p_document_id, p_party_id, p_site_id, p_lines, p_transition)
$$;

comment on function public.erp_convert_document(uuid, uuid, uuid, jsonb, text)
  is 'Convert an approved requisition into a purchase order, or an accepted quotation into a sales order.';

revoke all on function public.erp_convert_document(uuid, uuid, uuid, jsonb, text) from public;
revoke all on function public.erp_convert_document(uuid, uuid, uuid, jsonb, text) from anon;
grant execute on function public.erp_convert_document(uuid, uuid, uuid, jsonb, text) to authenticated;
grant execute on function public.erp_convert_document(uuid, uuid, uuid, jsonb, text) to service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values ('erp_convert_document', 'erp.convert_document',
        'Opens the target order and adds its lines. It authorises nothing itself: erp.open_document authorises the target type''s create permission, erp.add_document_line re-authorises it per line, and erp.transition_document authorises each move, so the call is gated exactly as the separate steps it replaces. Row security keeps the source document to the caller''s tenant.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

do $do$ begin perform erp.assert_public_api_safe(); end $do$;
