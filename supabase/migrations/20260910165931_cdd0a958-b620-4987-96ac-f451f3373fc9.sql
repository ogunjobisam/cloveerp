-- 1. Zero-value posting: cost-only documents post; the refusal explains itself.
do $do$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('erp.post_document_finance(uuid)'::regprocedure);

  v_new := replace(v_def,
$old$  if coalesce(v_value, 0) = 0 then
    raise exception 'CLOVEERP_ZERO_VALUE: % has no value to post', d.document_number
      using errcode = '23514',
      hint = 'A journal of zeroes balances and says nothing; it is noise in the '
             'ledger and a gap in the audit trail at the same time.';
  end if;$old$,
$new$  -- A despatch carries a cost even when nobody has priced the sale yet, and
  -- that cost is a real ledger consequence. Only a document with neither a
  -- value nor a stock cost has nothing to say.
  if coalesce(v_value, 0) = 0 and coalesce(v_cost, 0) = 0 then
    raise exception
      'CLOVEERP_NO_PRICE_TO_POST: % has no price on any line and no stock value, so there is nothing to post',
      d.document_number
      using errcode = '23514',
      hint = 'Put a unit price on each line — a despatch raised from an order takes the order''''s price — and post it again.';
  end if;$new$);

  if v_new = v_def then
    raise exception 'zero-value guard not found in erp.post_document_finance';
  end if;
  v_def := v_new;

  -- A zero line balances and says nothing, whichever side raised it.
  v_new := replace(v_def,
$old$    if v_side = 'debit' then v_dr := v_dr + v_amount;$old$,
$new$    if v_amount = 0 then
      v_no := v_no - 1;
      continue;
    end if;

    if v_side = 'debit' then v_dr := v_dr + v_amount;$new$);

  if v_new = v_def then
    raise exception 'journal line accumulation not found in erp.post_document_finance';
  end if;

  execute v_new;
end $do$;

-- 2. A receipt advances the order it was received against.
create or replace function erp.advance_orders_for_receipt(p_receipt_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  r         record;
  l         record;
  v_state   text;
  v_full    boolean;
  v_txn     text;
  v_moved   integer := 0;
begin
  for r in
    select distinct rel.to_document_id as order_id
      from erp.document_relation rel
     where rel.tenant_id = v_tenant
       and rel.from_document_id = p_receipt_id
       and rel.to_document_id is not null
  loop
    -- Fulfilled quantities are derived; refresh them before reading them.
    for l in
      select dl.id from erp.document_line dl
       where dl.tenant_id = v_tenant and dl.document_id = r.order_id
    loop
      perform erp.refresh_order_line_progress(l.id);
    end loop;

    select s.code into v_state
      from erp.object_state os
      join erp.state s on s.id = os.current_state_id
     where os.tenant_id = v_tenant and os.object_type = 'document'
       and os.object_id = r.order_id;

    select bool_and(coalesce(dl.quantity_fulfilled, 0) >= dl.quantity)
      into v_full
      from erp.document_line dl
     where dl.tenant_id = v_tenant and dl.document_id = r.order_id;

    v_txn := case
      when v_state = 'sent' and coalesce(v_full, false) then 'receive_all'
      when v_state = 'sent' then 'receive_partial'
      when v_state = 'partially_received' and coalesce(v_full, false) then 'receive_rest'
    end;

    if v_txn is null then
      continue;
    end if;

    -- The receipt is already posted. If the order cannot move — a guard, a
    -- permission, an approval — that is worth recording, not worth undoing a
    -- receipt for.
    begin
      perform erp.perform_transition(
        'document', r.order_id, v_txn,
        erp.document_transition_context(r.order_id, v_txn),
        'Goods received');
      v_moved := v_moved + 1;
    exception when others then
      perform erp.append_event(
        'document.progress_not_advanced', 'document', r.order_id,
        jsonb_build_object('transition', v_txn, 'reason', sqlerrm,
                           'receipt_id', p_receipt_id),
        null, null);
    end;
  end loop;

  return v_moved;
end $$;

comment on function erp.advance_orders_for_receipt is
  'Moves a purchase order out of Sent once goods have been received against '
  'it: partially received while quantities remain, received when none do.';

do $do$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('erp.transition_document(uuid,text,text)'::regprocedure);

  v_new := replace(v_def,
$old$  return v_to;
end;$old$,
$new$  -- An order that has been received in full should not still read "Sent".
  if coalesce(v_committed, false) and dt.base_type_code = 'receipt' then
    perform erp.advance_orders_for_receipt(p_document_id);
  end if;

  return v_to;
end;$new$);

  if v_new = v_def then
    raise exception 'return point not found in erp.transition_document';
  end if;

  execute v_new;
end $do$;

-- 3. Picking a sales order reserves what it needs first.
create or replace function erp.pick_document(
  p_document_id uuid,
  p_location_id uuid default null,
  p_batch_id uuid default null
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant    uuid := erp.require_tenant_id();
  d           erp.document%rowtype;
  l           record;
  a           record;
  v_reserved  integer := 0;
  v_picked    integer := 0;
  v_lines     integer := 0;
  v_short     numeric := 0;
begin
  select * into d from erp.document
   where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  perform erp.authorise('sales.despatch', d.entity_id, d.site_id, null,
                        'document', p_document_id);

  -- Pressing Pick used to find nothing, because reserving was a separate verb
  -- somebody had to know to press first. Picking now means both halves.
  for l in
    select dl.id from erp.document_line dl
     where dl.tenant_id = v_tenant and dl.document_id = p_document_id
     order by dl.line_no
  loop
    if not exists (select 1 from erp.allocation al
                    where al.tenant_id = v_tenant
                      and al.document_line_id = l.id
                      and al.status in ('reserved', 'committed', 'picked')) then
      perform erp.reserve_for_line(l.id, null);
      v_reserved := v_reserved + 1;
    end if;
  end loop;

  for a in
    select al.id, coalesce(al.unmet_quantity, 0) as unmet
      from erp.allocation al
     where al.tenant_id = v_tenant
       and al.document_id = p_document_id
       and al.status = 'reserved'
  loop
    v_lines  := v_lines + erp.commit_allocation(a.id, p_location_id, p_batch_id);
    v_picked := v_picked + 1;
    v_short  := v_short + a.unmet;
  end loop;

  return jsonb_build_object(
    'document_number', d.document_number,
    'reserved', v_reserved,
    'picked', v_picked,
    'pick_lines', v_lines,
    'shortfall', v_short);
end $$;

comment on function erp.pick_document is
  'Reserves any unreserved line on the order and then picks every reservation '
  'against real stock, so picking is one press rather than two.';

create or replace function public.erp_pick_document(
  p_document_id uuid,
  p_location_id uuid default null,
  p_batch_id uuid default null
) returns jsonb
language sql
security invoker
set search_path = ''
as $$ select erp.pick_document(p_document_id, p_location_id, p_batch_id) $$;

grant execute on function public.erp_pick_document(uuid, uuid, uuid) to authenticated, service_role;
revoke all on function public.erp_pick_document(uuid, uuid, uuid) from anon, public;
grant execute on function public.erp_pick_document(uuid, uuid, uuid) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values ('erp_pick_document', 'erp.pick_document',
        'Reserves and picks a sales order in one press. Gated on sales.despatch inside erp.pick_document(), and each reservation is gated again on sales.order inside erp.reserve_for_line().')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();
select erp.assert_public_api_safe();