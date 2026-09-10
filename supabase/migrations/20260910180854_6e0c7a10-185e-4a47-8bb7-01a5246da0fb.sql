-- One press, one whole document.
--
-- Raising a requisition took three round trips: open the header, add each line,
-- then price it. Every one of those is a separate transaction, so a failure
-- halfway leaves a half-made document for somebody to find and tidy. This does
-- the lot in one transaction: header, lines, and optionally the transition that
-- moves it on. Nothing new is authorised — erp.open_document and
-- erp.add_document_line still make every decision they made before.
create or replace function erp.create_document_full(
  p_type_code      text,
  p_party_id       uuid    default null,
  p_site_id        uuid    default null,
  p_their_ref      text    default null,
  p_required_date  date    default null,
  p_currency       text    default null,
  p_lines          jsonb   default '[]'::jsonb,
  p_transition     text    default null
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_id      uuid;
  v_base    text;
  d         erp.document%rowtype;
  ln        jsonb;
  v_no      integer := 0;
  v_added   integer := 0;
  v_price   bigint;
  v_qty     numeric;
  v_item    uuid;
  pr        record;
  v_moved   text := null;
  t         record;
begin
  v_id := erp.open_document(
    p_type_code, p_party_id, null, p_site_id, p_their_ref, p_required_date,
    case when p_currency is null then null else upper(p_currency)::character(3) end);

  select * into d from erp.document where tenant_id = v_tenant and id = v_id;

  select bt.code into v_base
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.tenant_id = v_tenant and dt.id = d.document_type_id;

  for ln in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb))
  loop
    v_no := v_no + 1;

    -- A blank row left at the bottom of a grid is not a line.
    if coalesce(ln->>'item_id', '') = '' and coalesce(ln->>'quantity', '') = '' then
      continue;
    end if;

    if coalesce(ln->>'item_id', '') = '' then
      raise exception 'CLOVEERP_LINE_NEEDS_ITEM: line % has no product', v_no
        using errcode = '23502',
        hint = 'Choose a product on every line, or remove the line.';
    end if;

    v_item := (ln->>'item_id')::uuid;
    v_qty  := coalesce(nullif(ln->>'quantity', '')::numeric, 0);

    if v_qty <= 0 then
      raise exception 'CLOVEERP_LINE_NEEDS_QUANTITY: line % has no quantity', v_no
        using errcode = '23514',
        hint = 'Put a quantity greater than nought on every line.';
    end if;

    v_price := coalesce(nullif(ln->>'unit_price_minor', '')::bigint, 0);

    -- A sales line nobody priced takes the customer's agreed price where there
    -- is one. Purchase lines already do this inside erp.add_document_line.
    if v_price = 0 and v_base is distinct from 'purchase_order' and d.party_id is not null then
      begin
        select * into pr from erp.resolve_price(v_item, d.party_id, v_qty, d.document_date, d.site_id);
        if found and (pr.currency is null or pr.currency = d.currency) then
          v_price := pr.amount_minor;
        end if;
      exception when others then
        null;  -- no catalogue answer is not a reason to refuse a draft line
      end;
    end if;

    perform erp.add_document_line(
      v_id, v_item, v_qty, v_price,
      nullif(ln->>'description', ''),
      nullif(ln->>'required_date', '')::date);

    v_added := v_added + 1;
  end loop;

  -- Moving it on is the same transition the button on the document performs,
  -- with the same guards and the same permission.
  if coalesce(p_transition, '') <> '' then
    if p_transition = 'auto' then
      select at.transition_code into v_moved
        from erp.available_transitions('document', v_id,
               erp.document_transition_context(v_id, null)) at
       where at.guard_passes and at.permitted and not at.is_automatic
       limit 1;
    else
      v_moved := p_transition;
    end if;

    if v_moved is not null then
      perform erp.transition_document(v_id, v_moved, 'Created and moved on');
    end if;
  end if;

  return jsonb_build_object(
    'document_id', v_id,
    'document_number', d.document_number,
    'lines', v_added,
    'moved_on', v_moved);
end;
$$;

comment on function erp.create_document_full(text, uuid, uuid, text, date, text, jsonb, text)
  is 'Header, lines and the next step in one transaction. All of it lands or none of it does.';

create or replace function public.erp_create_document_full(
  p_type_code      text,
  p_party_id       uuid    default null,
  p_site_id        uuid    default null,
  p_their_ref      text    default null,
  p_required_date  date    default null,
  p_currency       text    default null,
  p_lines          jsonb   default '[]'::jsonb,
  p_transition     text    default null
) returns jsonb
language sql
set search_path = ''
as $$
  select erp.create_document_full(p_type_code, p_party_id, p_site_id, p_their_ref,
                                  p_required_date, p_currency, p_lines, p_transition)
$$;

comment on function public.erp_create_document_full(text, uuid, uuid, text, date, text, jsonb, text)
  is 'Create a document and all of its lines in one step.';

revoke all on function public.erp_create_document_full(text, uuid, uuid, text, date, text, jsonb, text) from public;
revoke all on function public.erp_create_document_full(text, uuid, uuid, text, date, text, jsonb, text) from anon;
grant execute on function public.erp_create_document_full(text, uuid, uuid, text, date, text, jsonb, text) to authenticated;
grant execute on function public.erp_create_document_full(text, uuid, uuid, text, date, text, jsonb, text) to service_role;

-- It writes, deliberately, and says why.
insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values ('erp_create_document_full', 'erp.create_document_full',
        'Opens a document and adds its lines in one transaction. It authorises nothing itself: erp.open_document authorises the type''s create permission and erp.add_document_line re-authorises it per line, so the whole call is gated exactly as the three separate calls it replaces.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- The door is governed, in the same transaction that opened it.
do $do$ begin perform erp.assert_public_api_safe(); end $do$;
