set lock_timeout = '30s';

-- =============================================================================
-- 20261004910000  Goods go back to the supplier
-- -----------------------------------------------------------------------------
-- The second procure-to-pay gap the owner named on 1 October 2026, on top of
-- the supplier prepayment (20261004900000), whose payment run and transition
-- edits this one follows.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- A supplier credit note (erp.raise_supplier_credit_note(), from the goods
-- receipt) took the goods off the shelf and debited trade payables for the
-- billed part, on a row naming the credit note. Nothing took that debit to the
-- bill it credited: the bill stood owing in full, the next payment run offered
-- it in full, and a £20 credit on a £100 bill was paid £100. The supplier was
-- paid for goods they had taken back. And a return could only be for money:
-- goods sent back to be replaced reduced what we owed, and the replacement
-- then had nowhere to arrive. A rejection at inspection was a word on the
-- inspection, and nothing sent the goods back.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * A credit note pays the bill it credits (owner, 1 October 2026). As it
--     is issued, its billed part is taken to the open bills of the receipt it
--     returns, then of the order the receipt fulfilled, by the system: one
--     journal, supplier_credit.applied, Dr the payable (the bill, paid) Cr the
--     payable (the credit, used), on the one control account. The bill moves to
--     part_paid or paid, and the next run offers only the rest. A disputed bill
--     takes nothing until it is resolved.
--   * A credit for a bill already paid stays on the supplier's account and the
--     order's next bill takes it as it registers (owner). Otherwise it is
--     listed under Supplier credit notes on the Finance screen, where Finance
--     allocates it to another bill of the supplier's by hand
--     (erp_allocate_supplier_credit, finance.post).
--   * A return for replacement (owner: through goods received not invoiced).
--     erp_raise_supplier_credit_note takes p_outcome, credit or replacement. A
--     replacement credits nothing and charges no tax: the goods leave at what
--     they cost against goods received not invoiced (the receipt, unmade, in
--     full), the bill stands, and the return awaits the goods again.
--     erp_receive_replacement receives them against the return's own lines, a
--     goods receipt posted as any is, which clears goods received not invoiced.
--     The order is not reopened: an order billed is closed, and closed is the
--     end of its life. A replacement is left out of the VAT return, which it
--     does not concern.
--   * The supplier's return authorisation (RMA) is kept on the return, as
--     p_rma, and read with it.
--   * A rejection goes back (owner): erp_return_rejected raises the return of
--     a receipt's rejected inspection, its product and batch, as much as was
--     inspected and is still here, for credit or replacement, with the reason
--     Quality rejection and the inspection named. Once per inspection.
--   * Refusals, registered, and an event: supplier_credit.applied.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * No lifecycle of its own for a return (awaiting authorisation,
--     despatched, credited): the credit note's draft and issue carry it, and
--     the RMA is a field. A follow-up if returns wait on suppliers in practice.
--   * No refund a supplier pays back: a follow-up, with Cash in taught to bank
--     from a supplier. A credit nobody's bill takes stays listed.
--   * No carrier booked for the goods going back: a follow-up with inbound
--     carriers.
--   * The order stays as it was: a replacement is awaited on the return, not
--     on a closed order.
--
-- Proved by erp_test.supplier_return_outcome_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The registers
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_RETURN_OUTCOME_UNKNOWN',
  'Sending goods back to a supplier for something other than a credit or a replacement.',
  'Goods go back either for money, which the supplier credits, or for the same goods again, which they send; the ledger and the return differ for each, so the return says which.',
  'Choose credit or replacement.');

select erp.register_refusal('CLOVEERP_REPLACEMENT_NOT_AWAITED',
  'Receiving a replacement on something that awaits none: not a return for replacement, not issued, or more than is still awaited.',
  'A replacement arrives against goods sent back for one; receiving more than went back, or against a return for money, would put stock on the shelf that nobody is owed.',
  'Receive it on the return for replacement it answers, no more than it still awaits, which the return''s page shows.');

select erp.register_refusal('CLOVEERP_NOT_A_REJECTED_RECEIPT',
  'Returning goods from an inspection that did not reject a receipt''s goods, or whose goods have gone back already.',
  'Only goods a receipt brought in and an inspection rejected are sent back from the inspection, and only once; anything else is returned from its receipt.',
  'Disposition the inspection Reject first, or return the goods from the goods receipt''s page.');

select erp.register_refusal('CLOVEERP_SUPPLIER_CREDIT_NOTHING_LEFT',
  'Allocating from something that is not an issued supplier credit note, or one already used in full.',
  'Only what a supplier credited on an issued credit note, and no bill has taken, can pay a bill; allocating anything else would pay the bill with money the supplier never gave back.',
  'Pick the credit note from Supplier credit notes on the Finance screen, which lists only those with something left.');

select erp.register_refusal('CLOVEERP_SUPPLIER_CREDIT_OTHER_SUPPLIER',
  'Allocating a supplier''s credit note to a bill that is not theirs.',
  'A credit note is what one supplier gave back, and it pays only that supplier''s bills.',
  'Allocate it to one of the same supplier''s open bills, which Supplier credit notes offers on its row.');

select erp.register_refusal('CLOVEERP_SUPPLIER_CREDIT_OTHER_COMPANY',
  'Allocating a credit note to a bill of another company, ledger, control account or currency.',
  'A credit note reduces what one company owes, in one currency, on one creditors account, and each company''s books stand alone.',
  'Allocate it to a bill of the same company and currency, or move the balance between companies with a journal.');

select erp.register_refusal('CLOVEERP_SUPPLIER_CREDIT_EXCEEDS_LEFT',
  'Allocating more than is left of a supplier credit note.',
  'An allocation spends the credit; spending more than is left of it would pay the bill with credit the supplier never gave.',
  'Allocate no more than is left, which Supplier credit notes shows, or leave the amount out to allocate what is left.');

select erp.register_refusal('CLOVEERP_SUPPLIER_CREDIT_EXCEEDS_OWING',
  'Allocating more of a credit note to a bill than the bill still owes.',
  'A bill paid beyond what it owes would carry a credit of its own, and the rest of the credit belongs on the supplier''s account, where it already is.',
  'Allocate no more than the bill owes, or leave the amount out to allocate what it owes.');

select erp.register_refusal('CLOVEERP_SUPPLIER_CREDIT_AMOUNT_INVALID',
  'Allocating an amount of a credit note that is not positive.',
  'An allocation moves some of a credit to a bill; nothing, or less than nothing, moves nothing.',
  'Name a positive amount in minor units, or leave it out to allocate as much as the credit and the bill allow.');

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.supplier_credit.applied', 'en', 'Supplier credit applied to a bill', 'finance',
   'Event raised when what a supplier credited pays one of their bills.'),
  ('event.supplier_credit.applied', 'de', 'Lieferantengutschrift verrechnet', 'finance',
   'Ereignis, wenn eine Gutschrift eines Lieferanten mit einer seiner Rechnungen verrechnet wird.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values ('supplier_credit.applied', 1, 'document', 'finance', 'event.supplier_credit.applied',
        'What a supplier credited on a credit note paid one of their bills.',
        '{"type":"object","required":["value_minor","currency","credit_note_id"],
          "properties":{"reference":{"type":"string"},"value_minor":{"type":"integer"},
                        "currency":{"type":"string"},"posting_rule":{"type":"string"},
                        "credit_note_id":{"type":"string"},"credit_note_number":{"type":"string"},
                        "by_hand":{"type":"boolean"}}}'::jsonb,
        true)
on conflict do nothing;

do $event$
begin
  if (select count(*) from erp_ref.event_type et
       where et.code = 'supplier_credit.applied' and et.is_current and et.version = 1
         and et.aggregate_type = 'document' and et.name_key = 'event.supplier_credit.applied') <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: supplier_credit.applied is declared already, and not as 20261004910000 declares it';
  end if;
end
$event$;

-- ═════════════════════════════════════════════════════════════════════════════
-- B. A return for replacement
-- ═════════════════════════════════════════════════════════════════════════════

-- B1. Which returns are for replacement

create or replace function erp.supplier_return_is_replacement(p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- A supplier return the goods went back on to be replaced, not credited
  -- (20261004910000), as its outcome says.
  select exists (
    select 1 from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id
       and dt.base_type_code = 'return_to_supplier'
       and d.attributes ->> 'outcome' = 'replacement')
$$;

revoke all on function erp.supplier_return_is_replacement(uuid) from public, anon;

comment on function erp.supplier_return_is_replacement(uuid) is
  'Whether a supplier return went back to be replaced rather than credited (20261004910000).';

-- B2. A replacement unmakes the receipt in full
--
-- The credit note's rule debits goods received not invoiced by the unbilled
-- part and trade payables by the rest (value plus tax less unbilled). A
-- replacement charges no tax and is unbilled in full, so it debits goods
-- received not invoiced by its whole value and trade payables by nothing; the
-- replacement's receipt credits it back. Edited, not rewritten: the body
-- 20261001400000 left (md5 68a5a4b9…) becomes the credit's branch.

do $unbilled$
declare
  v_sig constant text := 'erp.document_unbilled_return_minor(uuid)';
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_new text;
begin
  if strpos(v_src, '20261004910000') > 0 then
    raise notice '% already unmakes a replacement in full; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '68a5a4b96cb5f00921dd2016d071e9f0' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004910000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  v_new := E'\n  -- A return for replacement is unbilled in full (20261004910000).\n'
        || E'  select case when erp.supplier_return_is_replacement(p_document_id)\n'
        || E'              then erp.document_value_minor(p_document_id)::bigint\n'
        || E'              else (' || regexp_replace(v_src, ';\s*$', '') || E')\n'
        || E'         end\n';
  if (length(v_def) - length(replace(v_def, v_src, ''))) / length(v_src) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % body found more than once in its definition', v_sig;
  end if;
  execute replace(v_def, v_src, v_new);
end
$unbilled$;

-- B3. A replacement is not on the VAT return
--
-- Edited, not rewritten: one anchor over erp.vat_entries() (md5 a96130a9…).

do $vat$
declare
  v_sig  constant text := 'erp.vat_entries(uuid,date,date)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$     where dt.base_type_code in ('invoice_reference', 'credit_reference', 'return_to_supplier')
       and j.source_code like 'document.%'$o$;
  v_new  constant text := $n$     where dt.base_type_code in ('invoice_reference', 'credit_reference', 'return_to_supplier')
       -- Goods sent back to be replaced are neither bought nor credited
       -- (20261004910000).
       and coalesce(d.attributes ->> 'outcome', '') <> 'replacement'
       and j.source_code like 'document.%'$n$;
begin
  if strpos(v_src, '20261004910000') > 0 then
    raise notice '% already leaves a replacement out; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'a96130a9e5aefb771fd1714513568104' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004910000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$vat$;

-- B4. Sending goods back, for credit or replacement

create or replace function erp.return_to_supplier(p_document_id uuid, p_reason_code text, p_reason text,
                                                  p_lines jsonb, p_tax_minor bigint, p_tax_code text,
                                                  p_outcome text default 'credit', p_rma text default null,
                                                  p_inspection_id uuid default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_outcome text := lower(btrim(coalesce(p_outcome, 'credit')));
  v_cn      uuid;
  d         erp.document%rowtype;
begin
  -- The return of what a goods receipt brought in (20261004910000), as
  -- erp.raise_supplier_credit_note() raises it, saying what for: credit, the
  -- supplier gives the money back, or replacement, they send the goods again
  -- and nothing is credited or taxed. With the supplier's authorisation, and
  -- the inspection that rejected the goods, where there are.
  if v_outcome not in ('credit', 'replacement') then
    raise exception 'CLOVEERP_RETURN_OUTCOME_UNKNOWN: goods go back for credit or replacement, not %',
      coalesce(p_outcome, 'nothing')
      using errcode = '22023', hint = 'Choose credit or replacement.';
  end if;

  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if found then
    perform erp.authorise('procurement.order', d.entity_id, d.site_id, null, 'document', p_document_id);
  end if;

  v_cn := erp.raise_supplier_credit_note(p_document_id, p_reason_code, p_reason, p_lines,
                                         case when v_outcome = 'replacement' then null else p_tax_minor end,
                                         p_tax_code);

  update erp.document x
     set attributes = coalesce(x.attributes, '{}'::jsonb)
                      || jsonb_build_object('outcome', v_outcome)
                      || case when nullif(btrim(coalesce(p_rma, '')), '') is null then '{}'::jsonb
                              else jsonb_build_object('rma', btrim(p_rma)) end
                      || case when p_inspection_id is null then '{}'::jsonb
                              else jsonb_build_object('inspection_id', p_inspection_id) end,
         updated_at = now()
   where x.tenant_id = v_tenant and x.id = v_cn;

  if v_outcome = 'replacement' then
    perform erp.state_supplier_tax(v_cn, 0, coalesce(nullif(btrim(p_tax_code), ''), 'S'),
                                   'sent back for a replacement: nothing is credited, so no tax is');
  end if;

  return v_cn;
end;
$$;

revoke all on function erp.return_to_supplier(uuid, text, text, jsonb, bigint, text, text, text, uuid) from public, anon;

comment on function erp.return_to_supplier(uuid, text, text, jsonb, bigint, text, text, text, uuid) is
  'Raises the return of what a goods receipt brought in, for credit or replacement, with the supplier''s '
  'authorisation and the rejecting inspection where there are (20261004910000). Authorises '
  'procurement.order in the receipt''s company and site.';

-- The door the receipt's page calls, widened by two arguments. Dropped and
-- made again, because a default added to a function's arguments is a new
-- function; its name, its allowance and its home are the same.

drop function if exists public.erp_raise_supplier_credit_note(uuid, text, text, jsonb, bigint, text);

create or replace function public.erp_raise_supplier_credit_note(p_document_id uuid, p_reason_code text,
                                                                 p_reason text default null,
                                                                 p_lines jsonb default null,
                                                                 p_tax_minor bigint default null,
                                                                 p_tax_code text default null,
                                                                 p_outcome text default 'credit',
                                                                 p_rma text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid := erp.return_to_supplier(p_document_id, p_reason_code, p_reason, p_lines,
                                      p_tax_minor, p_tax_code, p_outcome, p_rma, null);
begin
  return (select jsonb_build_object(
            'document_id', d.id,
            'document_number', d.document_number,
            'outcome', d.attributes ->> 'outcome',
            'rma', d.attributes ->> 'rma',
            'lines', (select count(*) from erp.document_line l
                       where l.tenant_id = d.tenant_id and l.document_id = d.id),
            'tax_minor', erp.document_tax_minor(d.id))
            from erp.document d
           where d.tenant_id = erp.current_tenant_id() and d.id = v_id);
end;
$$;

revoke all on function public.erp_raise_supplier_credit_note(uuid, text, text, jsonb, bigint, text, text, text) from public, anon;
grant execute on function public.erp_raise_supplier_credit_note(uuid, text, text, jsonb, bigint, text, text, text) to authenticated, service_role;

comment on function public.erp_raise_supplier_credit_note(uuid, text, text, jsonb, bigint, text, text, text) is
  'Sends goods a receipt brought in back to the supplier, for credit or replacement, as a draft '
  'supplier credit note (20260918170000, 20261004910000).';

update erp_meta.public_write_allowance
   set gate = 'erp.return_to_supplier',
       rationale = 'Raises a draft supplier credit note returning a receipt''s goods, for credit or replacement; authorises procurement.order in the receipt''s company and site.'
 where function_name = 'erp_raise_supplier_credit_note';

-- B5. What a return for replacement still awaits, and receiving it

create or replace function erp.replacement_awaited(p_return_line uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  -- What went back on a return line for replacement and has not come again
  -- (20261004910000): the line's quantity less the receipts against it that
  -- are not cancelled, as erp.receive_against() counts what an order line has
  -- had.
  select greatest(0, l.quantity - coalesce((
           select sum(rel.quantity)
             from erp.document_relation rel
             join erp.document rd on rd.tenant_id = rel.tenant_id and rd.id = rel.from_document_id
             join erp.document_type rdt on rdt.tenant_id = rd.tenant_id and rdt.id = rd.document_type_id
            where rel.tenant_id = l.tenant_id and rel.to_line_id = l.id
              and rel.relation_kind = 'fulfils' and rdt.base_type_code = 'receipt'
              and not rd.is_cancelled
              and coalesce(erp.object_current_state('document', rd.id), '') <> 'cancelled'), 0))
    from erp.document_line l
   where l.tenant_id = erp.current_tenant_id() and l.id = p_return_line
     and not l.is_cancelled
     and erp.supplier_return_is_replacement(l.document_id)
$$;

revoke all on function erp.replacement_awaited(uuid) from public, anon;

comment on function erp.replacement_awaited(uuid) is
  'What a line of a return for replacement still awaits from the supplier (20261004910000).';

create or replace function erp.receive_replacement(p_return uuid, p_quantity numeric default null,
                                                   p_post boolean default true)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  r        record;
  v_grn    uuid;
  v_rest   numeric;
  v_take   numeric;
  v_total  numeric;
  v_got    numeric := 0;
begin
  -- The goods a supplier sent again for a return for replacement
  -- (20261004910000): one goods receipt, received against the return's own
  -- lines, oldest line first, p_quantity in all or everything still awaited,
  -- and posted unless told not to. It posts as any receipt does, which credits
  -- goods received not invoiced back by what the return debited it.
  select x.* into d from erp.document x where x.tenant_id = v_tenant and x.id = p_return for update;
  if d.id is null or not erp.supplier_return_is_replacement(d.id)
     or erp.object_current_state('document', d.id) <> 'issued' then
    raise exception 'CLOVEERP_REPLACEMENT_NOT_AWAITED: % is not an issued return for replacement',
      coalesce(d.document_number, coalesce(p_return::text, 'nothing'))
      using errcode = '23514',
            hint = 'Receive it on the return for replacement it answers, no more than it still awaits, which the return''s page shows.';
  end if;

  perform erp.authorise('procurement.receive', d.entity_id, d.site_id, null, 'document', d.id);

  select coalesce(sum(erp.replacement_awaited(l.id)), 0) into v_total
    from erp.document_line l where l.tenant_id = v_tenant and l.document_id = d.id and not l.is_cancelled;
  v_rest := coalesce(p_quantity, v_total);
  if v_rest <= 0 or v_rest > v_total then
    raise exception 'CLOVEERP_REPLACEMENT_NOT_AWAITED: % awaits %, and % was to be received',
      d.document_number, v_total, v_rest
      using errcode = '23514',
            hint = 'Receive it on the return for replacement it answers, no more than it still awaits, which the return''s page shows.';
  end if;

  v_grn := erp.open_document('goods_receipt', d.party_id, d.entity_id, d.site_id,
                             coalesce(d.attributes ->> 'rma', d.document_number), null, d.currency);
  update erp.document x
     set notes = coalesce(x.notes, format('The replacement for %s', d.document_number)),
         attributes = coalesce(x.attributes, '{}'::jsonb) || jsonb_build_object('replaces', d.id),
         updated_at = now()
   where x.tenant_id = v_tenant and x.id = v_grn;

  for r in
    select l.id, erp.replacement_awaited(l.id) as awaited
      from erp.document_line l
     where l.tenant_id = v_tenant and l.document_id = d.id and not l.is_cancelled
     order by l.line_no
  loop
    exit when v_rest <= 0;
    continue when r.awaited <= 0;
    v_take := least(v_rest, r.awaited);
    perform erp.receive_against(v_grn, r.id, v_take, null);
    v_rest := v_rest - v_take;
    v_got := v_got + v_take;
  end loop;

  if coalesce(p_post, true) then
    perform erp.transition_document(v_grn, 'post', format('the replacement for %s', d.document_number));
  end if;

  return jsonb_build_object(
    'return_id', d.id,
    'return_number', d.document_number,
    'document_id', v_grn,
    'document_number', (select x.document_number from erp.document x where x.tenant_id = v_tenant and x.id = v_grn),
    'received', v_got,
    'awaited', v_total - v_got,
    'state', erp.object_current_state('document', v_grn));
end;
$$;

revoke all on function erp.receive_replacement(uuid, numeric, boolean) from public, anon;

comment on function erp.receive_replacement(uuid, numeric, boolean) is
  'Receives the goods a supplier sent again for a return for replacement, against the return''s own '
  'lines, and posts the receipt (20261004910000). Authorises procurement.receive in the return''s '
  'company and site.';

create or replace function public.erp_receive_replacement(p_return uuid, p_quantity numeric default null,
                                                          p_post boolean default true)
returns jsonb
language sql
set search_path = ''
as $$ select erp.receive_replacement(p_return, p_quantity, p_post) $$;

revoke all on function public.erp_receive_replacement(uuid, numeric, boolean) from public, anon;
grant execute on function public.erp_receive_replacement(uuid, numeric, boolean) to authenticated, service_role;

comment on function public.erp_receive_replacement(uuid, numeric, boolean) is
  'Receives the replacement for goods sent back to a supplier (20261004910000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_receive_replacement', 'erp.receive_replacement',
   'Receives the goods a supplier sent again for a return for replacement: opens and posts a goods receipt against the return''s lines; authorises procurement.receive in the return''s company and site.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/procurement', array['erp_receive_replacement']);

-- ═════════════════════════════════════════════════════════════════════════════
-- C. A credit note pays the bill
-- ═════════════════════════════════════════════════════════════════════════════

-- C1. What is left of a credit, and whether it fits a bill

create or replace function erp.supplier_credit_left(p_credit_note uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  -- What a supplier credited on an issued credit note and no bill has taken
  -- (20261004910000): the payable rows naming it, the credit less what bills
  -- have taken. Exactly what the ageing carries against it, negated.
  select case when exists (select 1 from erp.document d
                             join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
                            where d.tenant_id = erp.current_tenant_id() and d.id = p_credit_note
                              and dt.base_type_code = 'return_to_supplier')
              then (select greatest(0, coalesce(sum(si.debit_minor - si.credit_minor), 0))
                      from erp.subledger_item si
                     where si.tenant_id = erp.current_tenant_id() and si.document_id = p_credit_note
                       and si.control_kind = 'payable')
              else 0 end::bigint
$$;

revoke all on function erp.supplier_credit_left(uuid) from public, anon;

comment on function erp.supplier_credit_left(uuid) is
  'What is left of a supplier credit note for a bill to take (20261004910000).';

create or replace function erp.supplier_credit_fits_bill(p_credit_note uuid, p_bill uuid)
returns text
language sql
stable
set search_path = ''
as $$
  -- Null when the credit note may pay the bill (20261004910000); otherwise
  -- which refusal says why not.
  with cr as (
    select si.* from erp.subledger_item si
     where si.tenant_id = erp.current_tenant_id() and si.document_id = p_credit_note
       and si.control_kind = 'payable' and si.debit_minor > si.credit_minor
     order by si.posting_date, si.id limit 1),
  bill as (
    select si.* from erp.subledger_item si
      join erp.document b on b.tenant_id = si.tenant_id and b.id = si.document_id
      join erp.document_type bt on bt.tenant_id = b.tenant_id and bt.id = b.document_type_id
     where si.tenant_id = erp.current_tenant_id() and si.document_id = p_bill
       and bt.base_type_code = 'invoice_reference'
       and si.control_kind = 'payable' and si.credit_minor > si.debit_minor)
  select case
           when not exists (select 1 from bill)
             or exists (select 1 from bill, cr where bill.party_id is distinct from cr.party_id)
             then 'CLOVEERP_SUPPLIER_CREDIT_OTHER_SUPPLIER'
           when exists (select 1 from bill, cr
                         where bill.entity_id <> cr.entity_id or bill.ledger_id <> cr.ledger_id
                            or bill.control_account_id <> cr.control_account_id or bill.currency <> cr.currency)
             then 'CLOVEERP_SUPPLIER_CREDIT_OTHER_COMPANY'
         end
$$;

revoke all on function erp.supplier_credit_fits_bill(uuid, uuid) from public, anon;

-- C1b. A return, as its page reads it

create or replace function erp.supplier_return(p_return uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- A supplier return (20261004910000): what for, the supplier's
  -- authorisation, the inspection that rejected the goods, what is left of
  -- its credit, what a replacement still awaits line by line, the receipts
  -- that brought the replacement, and whether the reader may receive it.
  select jsonb_build_object(
           'return_id', d.id,
           'return_number', d.document_number,
           'outcome', coalesce(d.attributes ->> 'outcome', 'credit'),
           'rma', d.attributes ->> 'rma',
           'inspection_id', d.attributes ->> 'inspection_id',
           'state', erp.object_current_state('document', d.id),
           'currency', d.currency,
           'credit_left_minor', erp.supplier_credit_left(d.id),
           'awaited', coalesce((select sum(erp.replacement_awaited(l.id)) from erp.document_line l
                                 where l.tenant_id = d.tenant_id and l.document_id = d.id and not l.is_cancelled), 0),
           'lines', coalesce((select jsonb_agg(jsonb_build_object(
                                       'line_id', l.id, 'item', i.code, 'description', l.description,
                                       'quantity', l.quantity, 'awaited', erp.replacement_awaited(l.id))
                                     order by l.line_no)
                                from erp.document_line l
                                left join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
                               where l.tenant_id = d.tenant_id and l.document_id = d.id and not l.is_cancelled), '[]'::jsonb),
           'receipts', coalesce((select jsonb_agg(distinct jsonb_build_object(
                                          'document_id', rd.id, 'document_number', rd.document_number))
                                   from erp.document_relation rel
                                   join erp.document_line l on l.tenant_id = rel.tenant_id and l.id = rel.to_line_id
                                   join erp.document rd on rd.tenant_id = rel.tenant_id and rd.id = rel.from_document_id
                                  where rel.tenant_id = d.tenant_id and l.document_id = d.id
                                    and rel.relation_kind = 'fulfils' and not rd.is_cancelled), '[]'::jsonb),
           'may_receive', erp.supplier_return_is_replacement(d.id)
                          and erp.object_current_state('document', d.id) = 'issued'
                          and erp.has_permission('procurement.receive', d.entity_id, d.site_id))
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = erp.current_tenant_id() and d.id = p_return
     and dt.base_type_code = 'return_to_supplier'
$$;

revoke all on function erp.supplier_return(uuid) from public, anon;


-- C2. The allocation itself

create or replace function erp.apply_supplier_credit(p_credit_note uuid, p_bill uuid, p_amount_minor bigint,
                                                     p_by_hand boolean default false)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  cr        erp.subledger_item%rowtype;
  r         record;
  v_rule    uuid;
  v_version integer;
  v_event   uuid;
  v_journal uuid;
  v_rest    bigint;
  v_take    bigint;
  v_cn      text;
  v_bill    text;
begin
  -- Takes p_amount_minor of a supplier credit note to a bill
  -- (20261004910000), as erp.apply_prepayment() takes a prepayment: one
  -- journal, supplier_credit.applied, by the supplier_payment rule, Dr the
  -- payable (the bill, paid) Cr the payable (the credit, used), on the one
  -- control account; a credit naming the credit note, settled whole, and a
  -- debit naming the bill, its own items settled oldest first; then the bill
  -- says what it owes. Asks nothing; its callers decide.
  if coalesce(p_amount_minor, 0) <= 0 then
    return null;
  end if;

  select si.* into cr
    from erp.subledger_item si
   where si.tenant_id = v_tenant and si.document_id = p_credit_note and si.control_kind = 'payable'
     and si.debit_minor > si.credit_minor
   order by si.posting_date, si.id
   limit 1;

  select d.document_number into v_cn from erp.document d where d.tenant_id = v_tenant and d.id = p_credit_note;
  select d.document_number into v_bill from erp.document d where d.tenant_id = v_tenant and d.id = p_bill;

  select pr.id, pr.version into v_rule, v_version
    from erp.posting_rule pr
   where pr.tenant_id = v_tenant and pr.code = 'supplier_payment' and pr.status = 'active'
   order by pr.version desc limit 1;
  if v_rule is null then
    raise exception 'CLOVEERP_NO_PAYMENT_POSTING_RULE: paying a supplier has no promoted rule'
      using errcode = '23503',
      hint = 'Install procurement controls: erp_configure_procurement_controls().';
  end if;

  v_event := erp.append_event(
    'supplier_credit.applied', 'document', p_bill,
    jsonb_build_object('reference', v_bill, 'value_minor', p_amount_minor, 'currency', cr.currency,
                       'posting_rule', 'supplier_payment', 'credit_note_id', p_credit_note,
                       'credit_note_number', v_cn, 'by_hand', coalesce(p_by_hand, false)),
    cr.entity_id, null);

  insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, source_event_id,
                           posting_date, description, status)
  values (v_tenant, cr.entity_id, cr.ledger_id, 'supplier_credit.applied', v_event, current_date,
          format('Credit note %s applied to %s', coalesce(v_cn, 'a credit note'), coalesce(v_bill, 'a bill')),
          'draft')
  returning id into v_journal;

  insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                base_debit_minor, base_credit_minor, exchange_rate,
                                posting_rule_id, posting_rule_version, source_event_id, description)
  values (v_tenant, v_journal, 1, cr.control_account_id, p_amount_minor, 0, cr.currency, p_amount_minor, 0, 1,
          v_rule, v_version, v_event, 'the supplier''s bill, paid from their credit note'),
         (v_tenant, v_journal, 2, cr.control_account_id, 0, p_amount_minor, cr.currency, 0, p_amount_minor, 1,
          v_rule, v_version, v_event, 'the credit note, used');

  insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                  party_id, document_id, journal_id, currency, debit_minor, credit_minor,
                                  settled_minor, posting_date)
  values (v_tenant, cr.entity_id, cr.ledger_id, 'payable', cr.control_account_id,
          cr.party_id, p_credit_note, v_journal, cr.currency, 0, p_amount_minor, p_amount_minor, current_date),
         (v_tenant, cr.entity_id, cr.ledger_id, 'payable', cr.control_account_id,
          cr.party_id, p_bill, v_journal, cr.currency, p_amount_minor, 0, 0, current_date);

  v_rest := p_amount_minor;
  for r in
    select si.id, si.credit_minor - si.debit_minor - coalesce(si.settled_minor, 0) as owing
      from erp.subledger_item si
     where si.tenant_id = v_tenant and si.document_id = p_bill and si.control_kind = 'payable'
       and si.credit_minor - si.debit_minor - coalesce(si.settled_minor, 0) > 0
     order by coalesce(si.due_date, si.posting_date), si.id
       for update
  loop
    exit when v_rest <= 0;
    v_take := least(v_rest, r.owing);
    update erp.subledger_item
       set settled_minor = coalesce(settled_minor, 0) + v_take, updated_at = now()
     where id = r.id;
    v_rest := v_rest - v_take;
  end loop;

  update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
   where id = v_journal;

  perform erp.settle_paid_document(p_bill,
    format('paid from credit note %s', coalesce(v_cn, 'of the supplier''s')));

  return jsonb_build_object(
    'credit_note_id', p_credit_note,
    'credit_note_number', v_cn,
    'bill_id', p_bill,
    'bill_number', v_bill,
    'allocated_minor', p_amount_minor,
    'currency', cr.currency,
    'credit_left_minor', erp.supplier_credit_left(p_credit_note),
    'bill_owes_minor', erp.bill_owes_minor(p_bill),
    'bill_state', erp.object_current_state('document', p_bill),
    'journal_id', v_journal);
end;
$$;

revoke all on function erp.apply_supplier_credit(uuid, uuid, bigint, boolean) from public, anon;

comment on function erp.apply_supplier_credit(uuid, uuid, bigint, boolean) is
  'Takes an amount of a supplier credit note to a bill (20261004910000): a supplier_credit.applied '
  'journal by the supplier_payment rule, a row using the credit and one paying the bill, then '
  'erp.settle_paid_document(). Asks nothing; its callers decide.';

-- C3. By the system, as a credit note is issued and as a bill registers

create or replace function erp.supplier_credit_note_orders(p_credit_note uuid)
returns setof uuid
language sql
stable
set search_path = ''
as $$
  -- The purchase orders a credit note returns goods of (20261004910000), as
  -- erp.raise_supplier_credit_note() links them.
  select distinct rel.to_document_id
    from erp.document_relation rel
    join erp.document o on o.tenant_id = rel.tenant_id and o.id = rel.to_document_id
    join erp.document_type odt on odt.tenant_id = o.tenant_id and odt.id = o.document_type_id
   where rel.tenant_id = erp.current_tenant_id() and rel.from_document_id = p_credit_note
     and rel.relation_kind = 'returns' and odt.base_type_code = 'purchase_order'
$$;

revoke all on function erp.supplier_credit_note_orders(uuid) from public, anon;

create or replace function erp.apply_credit_note_to_bills(p_credit_note uuid)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        record;
  v_take   bigint;
  v_done   bigint := 0;
begin
  -- An issued credit note pays the bill it credits (20261004910000): the
  -- open bills of the receipt it returns first, then those of the order the
  -- receipt fulfilled, oldest first; registered or part paid, in the same
  -- books. What no bill takes stays on the supplier's account.
  for r in
    with receipts as (
      select distinct rel.to_document_id as receipt_id
        from erp.document_relation rel
       where rel.tenant_id = v_tenant and rel.from_document_id = p_credit_note
         and rel.relation_kind = 'returns'),
    bills as (
      select b.id, b.document_date, b.document_number, 0 as rank
        from erp.document_relation rel
        join erp.document b on b.tenant_id = rel.tenant_id and b.id = rel.from_document_id
       where rel.tenant_id = v_tenant and rel.relation_kind = 'invoices'
         and rel.to_document_id in (select receipt_id from receipts)
      union
      select b.id, b.document_date, b.document_number, 1
        from erp.document_relation rel
        join erp.document_line ol on ol.tenant_id = rel.tenant_id and ol.id = rel.to_line_id
        join erp.document b on b.tenant_id = rel.tenant_id and b.id = rel.from_document_id
       where rel.tenant_id = v_tenant and rel.relation_kind = 'invoices'
         and ol.document_id in (select erp.supplier_credit_note_orders(p_credit_note)))
    select x.id, min(x.rank) as rank, x.document_date, x.document_number
      from bills x
      join erp.document b on b.tenant_id = v_tenant and b.id = x.id
      join erp.document_type bt on bt.tenant_id = b.tenant_id and bt.id = b.document_type_id
     where bt.base_type_code = 'invoice_reference' and not b.is_cancelled
     group by x.id, x.document_date, x.document_number
     order by 2, 3, 4
  loop
    exit when erp.supplier_credit_left(p_credit_note) <= 0;
    continue when erp.object_current_state('document', r.id) not in ('registered', 'part_paid');
    continue when erp.supplier_credit_fits_bill(p_credit_note, r.id) is not null;
    v_take := least(erp.supplier_credit_left(p_credit_note), erp.bill_owes_minor(r.id));
    continue when v_take <= 0;
    perform erp.apply_supplier_credit(p_credit_note, r.id, v_take, false);
    v_done := v_done + v_take;
  end loop;
  return v_done;
end;
$$;

revoke all on function erp.apply_credit_note_to_bills(uuid) from public, anon;

comment on function erp.apply_credit_note_to_bills(uuid) is
  'Takes an issued supplier credit note to the open bills of the receipt it returns, then of its '
  'order, oldest first (20261004910000). Called as the credit note is issued.';

create or replace function erp.apply_credit_notes_to_bill(p_bill uuid)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        record;
  v_take   bigint;
  v_done   bigint := 0;
begin
  -- A bill registered against an order whose earlier credit no bill took
  -- takes it (owner, 1 October 2026; 20261004910000): issued credit notes of
  -- the bill's orders with something left, oldest first. Only a bill that
  -- stands: registered or part paid.
  if erp.object_current_state('document', p_bill) not in ('registered', 'part_paid') then
    return 0;
  end if;
  for r in
    select distinct cn.id, cn.document_date, cn.document_number
      from erp.document_relation brel
      join erp.document_line ol on ol.tenant_id = brel.tenant_id and ol.id = brel.to_line_id
      join erp.document_relation crel on crel.tenant_id = brel.tenant_id
                                     and crel.to_document_id = ol.document_id and crel.relation_kind = 'returns'
      join erp.document cn on cn.tenant_id = crel.tenant_id and cn.id = crel.from_document_id
      join erp.document_type cnt on cnt.tenant_id = cn.tenant_id and cnt.id = cn.document_type_id
     where brel.tenant_id = v_tenant and brel.from_document_id = p_bill and brel.relation_kind = 'invoices'
       and cnt.base_type_code = 'return_to_supplier' and not cn.is_cancelled
       and erp.object_current_state('document', cn.id) = 'issued'
     order by cn.document_date, cn.document_number
  loop
    exit when erp.bill_owes_minor(p_bill) <= 0;
    continue when erp.supplier_credit_left(r.id) <= 0;
    continue when erp.supplier_credit_fits_bill(r.id, p_bill) is not null;
    v_take := least(erp.supplier_credit_left(r.id), erp.bill_owes_minor(p_bill));
    continue when v_take <= 0;
    perform erp.apply_supplier_credit(r.id, p_bill, v_take, false);
    v_done := v_done + v_take;
  end loop;
  return v_done;
end;
$$;

revoke all on function erp.apply_credit_notes_to_bill(uuid) from public, anon;

comment on function erp.apply_credit_notes_to_bill(uuid) is
  'Takes what is left of the issued credit notes of a bill''s orders to the bill, oldest first '
  '(20261004910000). Called as a bill registers or its dispute is resolved.';

-- C4. The hooks
--
-- Edited, not rewritten: one anchor over erp.transition_document()'s body as
-- 20261004900000 left it (md5 fff4bab1…), after the bill takes its
-- prepayment and before the order is closed.

do $transition$
declare
  v_sig  constant text := 'erp.transition_document(uuid,text,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$    if erp.apply_prepayments_to_bill(p_document_id) > 0 then
      v_to := erp.object_current_state('document', p_document_id);
    end if;
  end if;
$o$;
  v_new  constant text := $n$    if erp.apply_prepayments_to_bill(p_document_id) > 0 then
      v_to := erp.object_current_state('document', p_document_id);
    end if;
    -- And whatever its supplier credited on the order and no bill took
    -- (20261004910000).
    if v_to in ('registered', 'part_paid') and erp.apply_credit_notes_to_bill(p_document_id) > 0 then
      v_to := erp.object_current_state('document', p_document_id);
    end if;
  end if;

  -- A supplier credit note pays the bill it credits as it is issued
  -- (20261004910000): its journal has just been posted above.
  if dt.base_type_code = 'return_to_supplier' and p_transition_code = 'issue' and v_to = 'issued' then
    perform erp.apply_credit_note_to_bills(p_document_id);
  end if;
$n$;
begin
  if strpos(v_src, '20261004910000') > 0 then
    raise notice '% already applies supplier credit; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'fff4bab128472d928a307fabbee54cbd' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004910000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$transition$;

-- C5. By hand, and the list Finance allocates from

create or replace function erp.allocate_supplier_credit(p_credit_note uuid, p_bill uuid,
                                                        p_amount_minor bigint default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  cr       erp.subledger_item%rowtype;
  v_cn     text;
  v_bill   text;
  v_left   bigint;
  v_owes   bigint;
  v_amount bigint;
  v_misfit text;
begin
  -- The credit note's first payable row, held while it is spent.
  select si.* into cr
    from erp.subledger_item si
    join erp.document d on d.tenant_id = si.tenant_id and d.id = si.document_id
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where si.tenant_id = v_tenant and si.document_id = p_credit_note and si.control_kind = 'payable'
     and si.debit_minor > si.credit_minor and dt.base_type_code = 'return_to_supplier'
   order by si.posting_date, si.id
   limit 1
     for update of si;
  v_cn := coalesce((select d.document_number from erp.document d where d.tenant_id = v_tenant and d.id = p_credit_note),
                   coalesce(p_credit_note::text, 'nothing'));
  if cr.id is null then
    raise exception 'CLOVEERP_SUPPLIER_CREDIT_NOTHING_LEFT: % is not an issued supplier credit note that credited anything', v_cn
      using errcode = '23503',
            hint = 'Pick the credit note from Supplier credit notes on the Finance screen, which lists only those with something left.';
  end if;

  perform erp.authorise('finance.post', cr.entity_id, null, null, 'party', cr.party_id);

  v_left := erp.supplier_credit_left(p_credit_note);
  if v_left <= 0 then
    raise exception 'CLOVEERP_SUPPLIER_CREDIT_NOTHING_LEFT: % has been used in full', v_cn
      using errcode = '23514',
            hint = 'Pick the credit note from Supplier credit notes on the Finance screen, which lists only those with something left.';
  end if;

  v_bill := coalesce((select d.document_number from erp.document d where d.tenant_id = v_tenant and d.id = p_bill),
                     coalesce(p_bill::text, 'nothing'));
  v_misfit := erp.supplier_credit_fits_bill(p_credit_note, p_bill);
  if v_misfit = 'CLOVEERP_SUPPLIER_CREDIT_OTHER_SUPPLIER' then
    raise exception 'CLOVEERP_SUPPLIER_CREDIT_OTHER_SUPPLIER: % is not a bill of the supplier who issued %', v_bill, v_cn
      using errcode = '23514',
            hint = 'Allocate it to one of the same supplier''s open bills, which Supplier credit notes offers on its row.';
  elsif v_misfit = 'CLOVEERP_SUPPLIER_CREDIT_OTHER_COMPANY' then
    raise exception 'CLOVEERP_SUPPLIER_CREDIT_OTHER_COMPANY: % is not in the books % credits (%, %)',
      v_bill, v_cn,
      coalesce((select e.code from erp.entity e where e.tenant_id = v_tenant and e.id = cr.entity_id), cr.entity_id::text),
      cr.currency
      using errcode = '23514',
            hint = 'Allocate it to a bill of the same company and currency, or move the balance between companies with a journal.';
  end if;

  perform 1 from erp.subledger_item si
   where si.tenant_id = v_tenant and si.document_id = p_bill and si.control_kind = 'payable'
   order by si.id
     for update;
  v_owes := erp.bill_owes_minor(p_bill);

  if p_amount_minor is not null and p_amount_minor <= 0 then
    raise exception 'CLOVEERP_SUPPLIER_CREDIT_AMOUNT_INVALID: an allocation is a positive amount, not %', p_amount_minor
      using errcode = '22023',
            hint = 'Name a positive amount in minor units, or leave it out to allocate as much as the credit and the bill allow.';
  end if;
  v_amount := coalesce(p_amount_minor, least(v_left, v_owes));
  if v_amount > v_left then
    raise exception 'CLOVEERP_SUPPLIER_CREDIT_EXCEEDS_LEFT: % is more than the % left of %', v_amount, v_left, v_cn
      using errcode = '23514',
            hint = 'Allocate no more than is left, which Supplier credit notes shows, or leave the amount out to allocate what is left.';
  end if;
  if v_owes <= 0 or v_amount > v_owes then
    raise exception 'CLOVEERP_SUPPLIER_CREDIT_EXCEEDS_OWING: % owes %, and % was to be allocated to it', v_bill, v_owes, v_amount
      using errcode = '23514',
            hint = 'Allocate no more than the bill owes, or leave the amount out to allocate what it owes.';
  end if;

  perform erp.require_cash_in_ledger_currency(cr.ledger_id, cr.currency);
  return erp.apply_supplier_credit(p_credit_note, p_bill, v_amount, true);
end;
$$;

revoke all on function erp.allocate_supplier_credit(uuid, uuid, bigint) from public, anon;

comment on function erp.allocate_supplier_credit(uuid, uuid, bigint) is
  'Takes a supplier credit note to a bill of the same supplier, company, ledger, control account and '
  'currency, by hand (20261004910000). Authorises finance.post in the credit''s company.';

create or replace function public.erp_allocate_supplier_credit(p_credit_note uuid, p_bill uuid,
                                                               p_amount_minor bigint default null)
returns jsonb
language sql
set search_path = ''
as $$ select erp.allocate_supplier_credit(p_credit_note, p_bill, p_amount_minor) $$;

revoke all on function public.erp_allocate_supplier_credit(uuid, uuid, bigint) from public, anon;
grant execute on function public.erp_allocate_supplier_credit(uuid, uuid, bigint) to authenticated, service_role;

comment on function public.erp_allocate_supplier_credit(uuid, uuid, bigint) is
  'Takes a supplier credit note to one of the supplier''s open bills (20261004910000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_allocate_supplier_credit', 'erp.allocate_supplier_credit',
   'Takes a supplier credit note to one of their bills: posts a supplier_credit.applied journal and two subledger rows, and moves the bill to part_paid or paid; authorises finance.post in the credit''s company.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/finance', array['erp_allocate_supplier_credit']);

create or replace function erp.supplier_credit_notes()
returns table(credit_note_id uuid, credit_note_number text, party_id uuid, party_name text, entity_id uuid,
              company text, currency char(3), issued_on date, left_minor bigint, rma text,
              allocatable boolean, bills jsonb)
language sql
stable
set search_path = ''
as $$
  -- Every issued supplier credit note with something no bill has taken
  -- (20261004910000), oldest first, with the supplier's open bills in the
  -- same company, control account and currency it may go to and whether the
  -- reader holds finance.post in its company. The door decides regardless.
  with cr as (
    select distinct on (si.document_id)
           si.document_id, si.party_id, si.entity_id, si.control_account_id, si.currency, si.posting_date
      from erp.subledger_item si
      join erp.document d on d.tenant_id = si.tenant_id and d.id = si.document_id
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where si.tenant_id = erp.current_tenant_id() and si.control_kind = 'payable'
       and si.debit_minor > si.credit_minor and dt.base_type_code = 'return_to_supplier'
     order by si.document_id, si.posting_date, si.id)
  select d.id, d.document_number, cr.party_id, p.name, cr.entity_id, e.code, cr.currency, cr.posting_date,
         erp.supplier_credit_left(d.id), d.attributes ->> 'rma',
         erp.has_permission('finance.post', cr.entity_id),
         coalesce((select jsonb_agg(jsonb_build_object(
                             'document_id', b.document_id, 'document_number', bd.document_number,
                             'owes_minor', b.outstanding_minor, 'due_on', b.due_on)
                           order by b.due_on, bd.document_number)
                     from erp.ageing_balance b
                     join erp.document bd on bd.tenant_id = b.tenant_id and bd.id = b.document_id
                     join erp.document_type bdt on bdt.tenant_id = bd.tenant_id and bdt.id = bd.document_type_id
                    where b.tenant_id = d.tenant_id and b.entity_id = cr.entity_id
                      and b.control_account_id = cr.control_account_id and b.control_kind = 'payable'
                      and b.currency = cr.currency and b.party_id = cr.party_id
                      and bdt.base_type_code = 'invoice_reference'
                      and b.outstanding_minor > 0), '[]'::jsonb)
    from cr
    join erp.document d on d.tenant_id = erp.current_tenant_id() and d.id = cr.document_id
    left join erp.party p on p.tenant_id = d.tenant_id and p.id = cr.party_id
    left join erp.entity e on e.tenant_id = d.tenant_id and e.id = cr.entity_id
   where erp.supplier_credit_left(d.id) > 0
   order by cr.posting_date, d.document_number
$$;

revoke all on function erp.supplier_credit_notes() from public, anon;

comment on function erp.supplier_credit_notes() is
  'The supplier credit notes with something no bill has taken, the bills each may pay and whether the '
  'reader may allocate it (20261004910000).';

create or replace function public.erp_supplier_credit_notes()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(s) order by s.issued_on, s.credit_note_number), '[]'::jsonb)
    from erp.supplier_credit_notes() s
$$;

revoke all on function public.erp_supplier_credit_notes() from public, anon;
grant execute on function public.erp_supplier_credit_notes() to authenticated, service_role;

comment on function public.erp_supplier_credit_notes() is
  'Supplier credit notes: what suppliers credited that no bill has taken, and which bills it may pay (20261004910000).';

-- The return's page reads it with the credit it left.

create or replace function public.erp_supplier_return(p_return uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$ select erp.supplier_return(p_return) $$;

revoke all on function public.erp_supplier_return(uuid) from public, anon;
grant execute on function public.erp_supplier_return(uuid) to authenticated, service_role;

comment on function public.erp_supplier_return(uuid) is
  'A supplier return: what for, its authorisation, its credit left and what a replacement awaits (20261004910000).';

comment on function erp.supplier_return(uuid) is
  'A supplier return as its page draws it: credit or replacement, the supplier''s authorisation, the '
  'rejecting inspection, its credit left, what a replacement awaits and the receipts that brought it '
  '(20261004910000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- D. A rejection goes back
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.return_rejected(p_inspection_id uuid, p_outcome text default 'credit',
                                               p_rma text default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  ins      erp.inspection%rowtype;
  v_line   uuid;
  v_left   numeric;
  v_qty    numeric;
  v_base   text;
begin
  -- The goods an inspection of a receipt rejected, back to the supplier
  -- (20261004910000): its product and batch on the receipt, as much as was
  -- inspected and is still here, for credit or replacement, with the reason
  -- Quality rejection and the inspection named on the return. Once.
  select * into ins from erp.inspection x where x.tenant_id = v_tenant and x.id = p_inspection_id for update;
  select dt.base_type_code into v_base
    from erp.document d join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and d.id = ins.document_id;
  if ins.id is null or ins.disposition is distinct from 'reject' or ins.status <> 'complete'
     or v_base is distinct from 'receipt'
     or erp.object_current_state('document', ins.document_id) <> 'posted' then
    raise exception 'CLOVEERP_NOT_A_REJECTED_RECEIPT: % is not a completed inspection that rejected a posted receipt''s goods',
      coalesce(p_inspection_id::text, 'nothing')
      using errcode = '23514',
            hint = 'Disposition the inspection Reject first, or return the goods from the goods receipt''s page.';
  end if;
  if exists (select 1 from erp.document d
              where d.tenant_id = v_tenant and d.attributes ->> 'inspection_id' = p_inspection_id::text
                and not d.is_cancelled
                and coalesce(erp.object_current_state('document', d.id), '') <> 'cancelled') then
    raise exception 'CLOVEERP_NOT_A_REJECTED_RECEIPT: the goods inspection % rejected have gone back already', p_inspection_id
      using errcode = '23505',
            hint = 'Disposition the inspection Reject first, or return the goods from the goods receipt''s page.';
  end if;

  select rl.id,
         rl.quantity - coalesce((select sum(rr.quantity) from erp.document_relation rr
                                  where rr.tenant_id = v_tenant and rr.to_line_id = rl.id
                                    and rr.relation_kind = 'returns'), 0)
    into v_line, v_left
    from erp.document_line rl
   where rl.tenant_id = v_tenant and rl.document_id = ins.document_id
     and not coalesce(rl.is_cancelled, false)
     and rl.item_id = ins.item_id
     and (ins.batch_id is null or rl.batch_id is not distinct from ins.batch_id)
   order by rl.line_no
   limit 1;
  v_qty := least(coalesce(ins.quantity_inspected, 0), coalesce(v_left, 0));
  if v_line is null or v_qty <= 0 then
    raise exception 'CLOVEERP_NOT_A_REJECTED_RECEIPT: none of what inspection % rejected is still here to go back', p_inspection_id
      using errcode = '23514',
            hint = 'Disposition the inspection Reject first, or return the goods from the goods receipt''s page.';
  end if;

  return erp.return_to_supplier(ins.document_id, 'QUALITY_REJECTION', 'Rejected at inspection',
                                jsonb_build_array(jsonb_build_object('line_id', v_line, 'quantity', v_qty)),
                                null, null, p_outcome, p_rma, p_inspection_id);
end;
$$;

revoke all on function erp.return_rejected(uuid, text, text) from public, anon;

comment on function erp.return_rejected(uuid, text, text) is
  'Sends back to the supplier what an inspection of a receipt rejected, for credit or replacement, as a '
  'draft supplier credit note naming the inspection, once (20261004910000). Authorises procurement.order.';

create or replace function public.erp_return_rejected(p_inspection_id uuid, p_outcome text default 'credit',
                                                      p_rma text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid := erp.return_rejected(p_inspection_id, p_outcome, p_rma);
begin
  return (select jsonb_build_object('document_id', d.id, 'document_number', d.document_number,
                                    'outcome', d.attributes ->> 'outcome')
            from erp.document d where d.tenant_id = erp.current_tenant_id() and d.id = v_id);
end;
$$;

revoke all on function public.erp_return_rejected(uuid, text, text) from public, anon;
grant execute on function public.erp_return_rejected(uuid, text, text) to authenticated, service_role;

comment on function public.erp_return_rejected(uuid, text, text) is
  'Sends what an inspection of a receipt rejected back to the supplier (20261004910000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_return_rejected', 'erp.return_rejected',
   'Raises a draft supplier credit note returning what an inspection of a receipt rejected; authorises procurement.order in the receipt''s company and site.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/quality', array['erp_return_rejected']);

-- ═════════════════════════════════════════════════════════════════════════════
-- E. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.return_receipt_line(p_receipt uuid)
returns uuid
language sql
stable
set search_path = ''
as $$
  -- The first line of a receipt (20261004910000).
  select l.id from erp.document_line l
   where l.tenant_id = erp.current_tenant_id() and l.document_id = p_receipt
   order by l.line_no limit 1
$$;

revoke all on function erp_test.return_receipt_line(uuid) from public, anon;

create or replace function erp_test.return_receipt(p_order uuid, p_quantity numeric)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  o     erp.document%rowtype;
  v_pol uuid;
  v_grn uuid;
begin
  -- p_quantity of the order's first line received and posted (20261004910000).
  select * into o from erp.document where tenant_id = erp.current_tenant_id() and id = p_order;
  select l.id into v_pol from erp.document_line l
   where l.tenant_id = o.tenant_id and l.document_id = o.id order by l.line_no limit 1;
  v_grn := erp.open_document('goods_receipt', o.party_id, o.entity_id, o.site_id);
  perform erp.receive_against(v_grn, v_pol, p_quantity, null);
  perform erp.transition_document(v_grn, 'post', null);
  return v_grn;
end;
$$;

revoke all on function erp_test.return_receipt(uuid, numeric) from public, anon;

create or replace function erp_test.supplier_return_outcome_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 11;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  s_buy    uuid := gen_random_uuid();
  s_fin    uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  v_entity uuid; v_site uuid; v_uom uuid; v_ccy char(3); v_item uuid;
  v_sa uuid; v_sb uuid;
  v_po uuid; v_po2 uuid; v_po3 uuid; v_po4 uuid;
  v_grn uuid; v_grn2 uuid; v_bill uuid; v_bill2 uuid; v_other uuid;
  v_cn uuid; v_cn2 uuid; v_cn3 uuid; v_ins uuid; v_ins2 uuid;
  v_bgross bigint; v_owes0 bigint; v_credit bigint;
  v_ret jsonb; v_list jsonb; v_row jsonb; v_alloc jsonb; v_line jsonb; v_prop uuid; v_recv jsonb;
  v_grni0 bigint; v_grni1 bigint; v_grni2 bigint; v_stock0 bigint; v_stock1 bigint;
  v_vat integer; v_n integer; v_n2 integer;
  v_err text; v_err2 text; v_err3 text; v_err4 text; v_err5 text; v_tie text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation that buys, returns and pays, with two administrators, a buyer and a finance clerk';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzsro-' || v_tag, 'Supplier Return Outcome Suite',
      'admin@zzsro-' || v_tag || '.test', 'Return Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzsro-' || v_tag || '.test'),
           (a2, 'second@zzsro-' || v_tag || '.test'),
           (s_buy, 'buyer@zzsro-' || v_tag || '.test'),
           (s_fin, 'clerk@zzsro-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    res := public.erp_invite_principal('second@zzsro-' || v_tag || '.test', 'Second Admin');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('buyer@zzsro-' || v_tag || '.test', 'Bea Buyer');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'purchasing', null, null, 'buys');
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('clerk@zzsro-' || v_tag || '.test', 'Cal Clerk');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'finance', null, null, 'pays');
    perform set_config('request.jwt.claims', json_build_object('sub', s_fin)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'its company, site, unit, product and two suppliers';
    select e.id, e.base_currency into v_entity, v_ccy
      from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    if v_site is null then
      insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
      values (rb.tenant_id, v_entity, 'ZRMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    end if;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZREA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZRCOAT', 'Returned Coat', v_uom, 'active') returning id into v_item;
    v_sa := erp_test.cash_payment_supplier('ZRBRAND');
    v_sb := erp_test.cash_payment_supplier('ZROTHER');

    -- ── 1. The registers ────────────────────────────────────────────────────
    v_step := 'the doors, their refusals, the event and their screens';
    v_cases := v_cases + 1;
    case_name := 'the four write doors are on the allow-list under their gates and on their screens'' help, the nine refusals are registered with a next action, and supplier_credit.applied is current and named in English and German';
    passed := v_state is null
          and (select count(*) from erp_meta.public_write_allowance a
                where (a.function_name, a.gate) in (('erp_raise_supplier_credit_note', 'erp.return_to_supplier'),
                                                    ('erp_receive_replacement', 'erp.receive_replacement'),
                                                    ('erp_allocate_supplier_credit', 'erp.allocate_supplier_credit'),
                                                    ('erp_return_rejected', 'erp.return_rejected'))) = 4
          and exists (select 1 from erp_ref.help_topic h
                       where h.screen_path = '/procurement' and 'erp_receive_replacement' = any (h.actions))
          and exists (select 1 from erp_ref.help_topic h
                       where h.screen_path = '/finance' and 'erp_allocate_supplier_credit' = any (h.actions))
          and exists (select 1 from erp_ref.help_topic h
                       where h.screen_path = '/quality' and 'erp_return_rejected' = any (h.actions))
          and (select count(*) from erp_ref.refusal f
                where f.code in ('CLOVEERP_RETURN_OUTCOME_UNKNOWN', 'CLOVEERP_REPLACEMENT_NOT_AWAITED',
                                 'CLOVEERP_NOT_A_REJECTED_RECEIPT', 'CLOVEERP_SUPPLIER_CREDIT_NOTHING_LEFT',
                                 'CLOVEERP_SUPPLIER_CREDIT_OTHER_SUPPLIER', 'CLOVEERP_SUPPLIER_CREDIT_OTHER_COMPANY',
                                 'CLOVEERP_SUPPLIER_CREDIT_EXCEEDS_LEFT', 'CLOVEERP_SUPPLIER_CREDIT_EXCEEDS_OWING',
                                 'CLOVEERP_SUPPLIER_CREDIT_AMOUNT_INVALID')
                  and coalesce(f.next_action, '') <> '') = 9
          and exists (select 1 from erp_ref.event_type et where et.code = 'supplier_credit.applied' and et.is_current)
          and (select count(*) from erp_ref.resource x
                where x.key = 'event.supplier_credit.applied' and x.locale in ('en', 'de')) = 2;
    detail := coalesce(v_state, 'registers read');
    return next;

    -- ── 2. A credit pays the bill it credits ────────────────────────────────
    v_step := 'ten coats received and billed, two of them sent back for credit with the supplier''s authorisation';
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 10, 10000, 'ZRO2');
    v_grn := erp_test.return_receipt(v_po, 10);
    v_bill := erp.bill_from_receipt(v_grn, 'ZRO-INV-2', current_date, current_date + 30, true);
    select dv.gross_minor::bigint into v_bgross from erp.document_view dv where dv.id = v_bill;
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    v_ret := public.erp_raise_supplier_credit_note(v_grn, 'DAMAGED_ARRIVAL', 'two torn',
               jsonb_build_array(jsonb_build_object('line_id', erp_test.return_receipt_line(v_grn), 'quantity', 2)),
               null, null, 'credit', 'RMA-77');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cn := (v_ret ->> 'document_id')::uuid;
    perform erp.transition_document(v_cn, 'issue', null);
    select coalesce(sum(si.debit_minor - si.credit_minor), 0) into v_credit
      from erp.subledger_item si
      join erp.journal j on j.id = si.journal_id and j.source_code like 'document.%'
     where si.tenant_id = rb.tenant_id and si.document_id = v_cn and si.control_kind = 'payable';
    v_prop := erp.propose_payment_run(current_date, null, interval '60 days');
    select to_jsonb(l) into v_line from erp.payment_proposal_line l
     where l.tenant_id = rb.tenant_id and l.payment_proposal_id = v_prop and l.document_id = v_bill;
    begin
      v_tie := erp.assert_ageing_equals_control();
      v_tie := 'ties';
    exception when others then v_tie := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'two of ten coats sent back for credit with an RMA: the credit note keeps the outcome and the RMA, and as it is issued it pays the bill it credits by itself, Part paid, owing the rest, nothing left of the credit, a supplier_credit.applied journal netting to nothing, the ageing tied, and the next run offering only the rest';
    passed := v_state is null
          and v_ret ->> 'outcome' = 'credit'
          and v_ret ->> 'rma' = 'RMA-77'
          and v_credit = 2 * 10000
          and erp.object_current_state('document', v_bill) = 'part_paid'
          and erp.bill_owes_minor(v_bill) = v_bgross - v_credit
          and erp.supplier_credit_left(v_cn) = 0
          and exists (select 1 from erp.journal j
                       where j.tenant_id = rb.tenant_id and j.source_code = 'supplier_credit.applied'
                         and j.status = 'posted'
                         and (select count(distinct jl.account_id) from erp.journal_line jl where jl.journal_id = j.id) = 1
                         and (select sum(jl.debit_minor) - sum(jl.credit_minor) from erp.journal_line jl
                               where jl.journal_id = j.id) = 0)
          and v_tie = 'ties'
          and v_line is not null
          and (v_line ->> 'amount_minor')::bigint = v_bgross - v_credit
          and (erp.supplier_return(v_cn) ->> 'rma') = 'RMA-77';
    detail := coalesce(v_state, left(format('ret %s; credit %s; bill %s owes %s of %s; line %s; %s',
      v_ret, v_credit, erp.object_current_state('document', v_bill), erp.bill_owes_minor(v_bill), v_bgross,
      v_line ->> 'amount_minor', v_tie), 700));
    return next;

    -- ── 3. Credit on a bill already paid, taken by the order's next bill ────
    v_step := 'a bill paid in full, then goods returned for credit, then the rest of the order billed';
    v_po2 := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 5, 10000, 'ZRO3');
    v_grn := erp_test.return_receipt(v_po2, 3);
    v_bill := erp.bill_from_receipt(v_grn, 'ZRO-INV-3A', current_date, current_date + 30, true);
    perform erp_test.prepayment_run(a1, a2, null, array[v_bill]);
    v_cn2 := erp.return_to_supplier(v_grn, 'DAMAGED_ARRIVAL', 'one torn',
               jsonb_build_array(jsonb_build_object('line_id', erp_test.return_receipt_line(v_grn), 'quantity', 1)),
               null, null, 'credit', null, null);
    perform erp.transition_document(v_cn2, 'issue', null);
    v_list := public.erp_supplier_credit_notes();
    select x into v_row from jsonb_array_elements(v_list) x where x ->> 'credit_note_id' = v_cn2::text;
    v_grn2 := erp_test.return_receipt(v_po2, 2);
    v_bill2 := erp.bill_from_receipt(v_grn2, 'ZRO-INV-3B', current_date, current_date + 30, true);
    select dv.gross_minor::bigint into v_bgross from erp.document_view dv where dv.id = v_bill2;
    v_cases := v_cases + 1;
    case_name := 'a credit for a bill already paid stays on the supplier''s account, listed under Supplier credit notes with what is left and not offered to the bill it was paid; the order''s next bill takes it as it registers, Part paid, and nothing is left';
    passed := v_state is null
          and erp.object_current_state('document', v_bill) = 'paid'
          and v_row is not null
          and (v_row ->> 'left_minor')::bigint = 10000
          and not exists (select 1 from jsonb_array_elements(v_row -> 'bills') b
                           where (b ->> 'document_id')::uuid = v_bill)
          and erp.object_current_state('document', v_bill2) = 'part_paid'
          and erp.bill_owes_minor(v_bill2) = v_bgross - 10000
          and erp.supplier_credit_left(v_cn2) = 0;
    detail := coalesce(v_state, left(format('first %s; listed %s; second %s owes %s of %s; left %s',
      erp.object_current_state('document', v_bill), v_row, erp.object_current_state('document', v_bill2),
      erp.bill_owes_minor(v_bill2), v_bgross, erp.supplier_credit_left(v_cn2)), 600));
    return next;

    -- ── 4. Allocating a credit by hand ──────────────────────────────────────
    v_step := 'a credit no bill takes, allocated by the finance clerk to a bill of another order';
    v_po3 := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 2, 10000, 'ZRO4');
    v_grn := erp_test.return_receipt(v_po3, 2);
    v_bill := erp.bill_from_receipt(v_grn, 'ZRO-INV-4', current_date, current_date + 30, true);
    perform erp_test.prepayment_run(a1, a2, null, array[v_bill]);
    v_cn3 := erp.return_to_supplier(v_grn, 'WRONG_ITEM', 'the wrong colour', null, null, null, 'credit', null, null);
    perform erp.transition_document(v_cn3, 'issue', null);
    v_po4 := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 1, 30000, 'ZRO4B');
    v_other := erp.bill_from_receipt(erp_test.return_receipt(v_po4, 1), 'ZRO-INV-4B', current_date, current_date + 30, true);
    select dv.gross_minor::bigint into v_bgross from erp.document_view dv where dv.id = v_other;
    select x into v_row from jsonb_array_elements(public.erp_supplier_credit_notes()) x
     where x ->> 'credit_note_id' = v_cn3::text;
    perform set_config('request.jwt.claims', json_build_object('sub', s_fin)::text, true);
    v_alloc := public.erp_allocate_supplier_credit(v_cn3, v_other, 5000);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    begin
      v_tie := erp.assert_ageing_equals_control();
      v_tie := 'ties';
    exception when others then v_tie := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'Supplier credit notes offers the supplier''s open bill of another order, and the finance clerk allocates part of the credit to it by hand: the bill is Part paid, the rest of the credit stays listed, and the ageing ties';
    passed := v_state is null
          and v_row is not null
          and (v_row ->> 'left_minor')::bigint = 20000
          and (v_row ->> 'allocatable')::boolean
          and exists (select 1 from jsonb_array_elements(v_row -> 'bills') b where (b ->> 'document_id')::uuid = v_other)
          and (v_alloc ->> 'allocated_minor')::bigint = 5000
          and (v_alloc ->> 'credit_left_minor')::bigint = 15000
          and v_alloc ->> 'bill_state' = 'part_paid'
          and exists (select 1 from erp.event e where e.tenant_id = rb.tenant_id
                         and e.event_type = 'supplier_credit.applied' and e.aggregate_id = v_other
                         and (e.payload ->> 'by_hand')::boolean)
          and v_tie = 'ties';
    detail := coalesce(v_state, left(format('listed %s; allocated %s; %s', v_row, v_alloc, v_tie), 600));
    return next;

    -- ── 5. What allocating a credit by hand refuses ─────────────────────────
    v_step := 'allocations the credit or the bill cannot take, and somebody who may only buy';
    v_bill2 := erp.bill_from_receipt(
      erp_test.return_receipt(erp_test.prepayment_order(v_entity, v_site, v_item, v_sb, 1, 10000, 'ZRO5'), 1),
      'ZRO-INV-5', current_date, current_date + 30, true);
    select count(*) into v_n from erp.journal j where j.tenant_id = rb.tenant_id and j.source_code = 'supplier_credit.applied';
    begin
      perform public.erp_allocate_supplier_credit(v_cn3, v_bill2, null);
      v_err := 'allocated';
    exception when others then v_err := sqlerrm; end;
    begin
      perform public.erp_allocate_supplier_credit(v_cn, v_other, null);
      v_err2 := 'allocated';
    exception when others then v_err2 := sqlerrm; end;
    begin
      perform public.erp_allocate_supplier_credit(v_cn3, v_other, 15001);
      v_err3 := 'allocated';
    exception when others then v_err3 := sqlerrm; end;
    begin
      perform public.erp_allocate_supplier_credit(v_cn3, v_other, 0);
      v_err4 := 'allocated';
    exception when others then v_err4 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    begin
      perform public.erp_allocate_supplier_credit(v_cn3, v_other, null);
      v_err5 := 'allocated';
    exception when others then v_err5 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select count(*) into v_n2 from erp.journal j where j.tenant_id = rb.tenant_id and j.source_code = 'supplier_credit.applied';
    v_cases := v_cases + 1;
    case_name := 'another supplier''s bill, a credit used in full, more than is left, nought, and a buyer without finance.post are each refused by name, and nothing is written';
    passed := v_state is null
          and v_err like 'CLOVEERP_SUPPLIER_CREDIT_OTHER_SUPPLIER:%'
          and v_err2 like 'CLOVEERP_SUPPLIER_CREDIT_NOTHING_LEFT:%'
          and v_err3 like 'CLOVEERP_SUPPLIER_CREDIT_EXCEEDS_LEFT:%'
          and v_err4 like 'CLOVEERP_SUPPLIER_CREDIT_AMOUNT_INVALID:%'
          and v_err5 like 'CLOVEERP_PERMISSION_DENIED: finance.post%'
          and v_n2 = v_n
          and erp.supplier_credit_left(v_cn3) = 15000;
    detail := coalesce(v_state, left(format('%s | %s | %s | %s | %s', v_err, v_err2, v_err3, v_err4, v_err5), 700));
    return next;

    -- ── 6. More than the bill owes ──────────────────────────────────────────
    v_step := 'the rest of the credit allocated, and then more';
    v_owes0 := erp.bill_owes_minor(v_other);
    v_alloc := public.erp_allocate_supplier_credit(v_cn3, v_other, null);
    begin
      perform public.erp_allocate_supplier_credit(v_cn3, v_other, erp.bill_owes_minor(v_other) + 1);
      v_err := 'allocated';
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'left out, the amount is the lesser of what is left and what the bill owes; beyond what the bill owes is refused by name';
    passed := v_state is null
          and (v_alloc ->> 'allocated_minor')::bigint = least(15000, v_owes0)
          and v_err like any (array['CLOVEERP_SUPPLIER_CREDIT_EXCEEDS_OWING:%', 'CLOVEERP_SUPPLIER_CREDIT_NOTHING_LEFT:%',
                                    'CLOVEERP_SUPPLIER_CREDIT_EXCEEDS_LEFT:%']);
    detail := coalesce(v_state, left(format('%s; %s', v_alloc, v_err), 500));
    return next;

    -- ── 7. A return for replacement ─────────────────────────────────────────
    v_step := 'four coats received and billed, one sent back for a replacement';
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 4, 10000, 'ZRO7');
    v_grn := erp_test.return_receipt(v_po, 4);
    v_bill := erp.bill_from_receipt(v_grn, 'ZRO-INV-7', current_date, current_date + 30, true);
    v_owes0 := erp.bill_owes_minor(v_bill);
    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0) into v_grni0
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
      join erp.account a on a.id = jl.account_id
     where jl.tenant_id = rb.tenant_id and a.code = '2100';
    v_ret := public.erp_raise_supplier_credit_note(v_grn, 'DAMAGED_ARRIVAL', 'one stained',
               jsonb_build_array(jsonb_build_object('line_id', erp_test.return_receipt_line(v_grn), 'quantity', 1)),
               null, null, 'replacement', 'RMA-88');
    v_cn := (v_ret ->> 'document_id')::uuid;
    perform erp.transition_document(v_cn, 'issue', null);
    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0) into v_grni1
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
      join erp.account a on a.id = jl.account_id
     where jl.tenant_id = rb.tenant_id and a.code = '2100';
    select count(*) into v_vat from erp.vat_entries(null, null, null) v where v.document_id = v_cn;
    begin
      v_tie := erp.assert_ageing_equals_control();
      v_tie := 'ties';
    exception when others then v_tie := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'one coat sent back for a replacement credits nothing and charges no tax: its journal debits goods received not invoiced by its value and touches no trade payable, the bill owes what it did, the return awaits one coat, it is not on the VAT return, and the ageing ties';
    passed := v_state is null
          and v_ret ->> 'outcome' = 'replacement'
          and (v_ret ->> 'tax_minor')::bigint = 0
          and v_grni1 - v_grni0 = 10000
          and not exists (select 1 from erp.subledger_item si
                           where si.tenant_id = rb.tenant_id and si.document_id = v_cn and si.control_kind = 'payable')
          and erp.bill_owes_minor(v_bill) = v_owes0
          and (erp.supplier_return(v_cn) ->> 'awaited')::numeric = 1
          and (erp.supplier_return(v_cn) ->> 'may_receive')::boolean
          and v_vat = 0
          and v_tie = 'ties';
    detail := coalesce(v_state, left(format('ret %s; grni %s; bill owes %s was %s; read %s; vat %s; %s',
      v_ret, v_grni1 - v_grni0, erp.bill_owes_minor(v_bill), v_owes0, erp.supplier_return(v_cn), v_vat, v_tie), 700));
    return next;

    -- ── 8. The replacement arrives ──────────────────────────────────────────
    v_step := 'the replacement received against the return, and then one more';
    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0) into v_stock0
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
      join erp.account a on a.id = jl.account_id
     where jl.tenant_id = rb.tenant_id and a.code = '1200';
    v_recv := public.erp_receive_replacement(v_cn, null, true);
    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0) into v_grni2
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
      join erp.account a on a.id = jl.account_id
     where jl.tenant_id = rb.tenant_id and a.code = '2100';
    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0) into v_stock1
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
      join erp.account a on a.id = jl.account_id
     where jl.tenant_id = rb.tenant_id and a.code = '1200';
    begin
      perform public.erp_receive_replacement(v_cn, 1, true);
      v_err := 'received';
    exception when others then v_err := sqlerrm; end;
    begin
      perform public.erp_receive_replacement(v_cn3, 1, true);
      v_err2 := 'received';
    exception when others then v_err2 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'the replacement is received against the return and posted: the coat is back on the shelf, goods received not invoiced is where it was before the return, the return awaits nothing and names the receipt, the bill is untouched, and receiving again, or on a return for credit, is refused by name';
    passed := v_state is null
          and (v_recv ->> 'received')::numeric = 1
          and (v_recv ->> 'awaited')::numeric = 0
          and v_recv ->> 'state' = 'posted'
          and v_grni2 = v_grni0
          and v_stock1 - v_stock0 = 10000
          and (erp.supplier_return(v_cn) ->> 'awaited')::numeric = 0
          and jsonb_array_length(erp.supplier_return(v_cn) -> 'receipts') = 1
          and erp.bill_owes_minor(v_bill) = v_owes0
          and v_err like 'CLOVEERP_REPLACEMENT_NOT_AWAITED:%'
          and v_err2 like 'CLOVEERP_REPLACEMENT_NOT_AWAITED:%';
    detail := coalesce(v_state, left(format('recv %s; grni %s→%s; stock +%s; %s | %s',
      v_recv, v_grni0, v_grni2, v_stock1 - v_stock0, v_err, v_err2), 700));
    return next;

    -- ── 9. Neither credit nor replacement ───────────────────────────────────
    v_step := 'a return for something else';
    begin
      perform public.erp_raise_supplier_credit_note(v_grn, 'DAMAGED_ARRIVAL', 'scuffed', null, null, null, 'refund', null);
      v_err := 'raised';
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a return for something other than credit or replacement is refused by name';
    passed := v_state is null and v_err like 'CLOVEERP_RETURN_OUTCOME_UNKNOWN:%';
    detail := coalesce(v_state, left(v_err, 300));
    return next;

    -- ── 10. A rejection goes back ───────────────────────────────────────────
    v_step := 'six coats received, three rejected at inspection, returned from the inspection, and again';
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 6, 10000, 'ZRO10');
    v_grn := erp_test.return_receipt(v_po, 6);
    insert into erp.inspection (tenant_id, entity_id, site_id, item_id, document_id, quantity_inspected,
                                sample_size, status, disposition, disposition_at, started_at, completed_at)
    values (rb.tenant_id, v_entity, v_site, v_item, v_grn, 3, 3, 'complete', 'reject', now(), now(), now())
    returning id into v_ins;
    insert into erp.inspection (tenant_id, entity_id, site_id, item_id, document_id, quantity_inspected,
                                sample_size, status, disposition, disposition_at, started_at, completed_at)
    values (rb.tenant_id, v_entity, v_site, v_item, v_grn, 3, 3, 'complete', 'accept', now(), now(), now())
    returning id into v_ins2;
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    v_ret := public.erp_return_rejected(v_ins, 'credit', 'RMA-99');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cn := (v_ret ->> 'document_id')::uuid;
    begin
      perform public.erp_return_rejected(v_ins, 'credit', null);
      v_err := 'returned';
    exception when others then v_err := sqlerrm; end;
    begin
      perform public.erp_return_rejected(v_ins2, 'credit', null);
      v_err2 := 'returned';
    exception when others then v_err2 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'three coats rejected at inspection go back from the inspection: a draft return of three for credit, reason Quality rejection, naming the inspection and its RMA; returning them again, or from an inspection that accepted, is refused by name';
    passed := v_state is null
          and v_cn is not null
          and erp.object_current_state('document', v_cn) = 'draft'
          and (select sum(l.quantity) from erp.document_line l where l.document_id = v_cn) = 3
          and (select d.attributes ->> 'reason_code' from erp.document d where d.id = v_cn) = 'QUALITY_REJECTION'
          and (select d.attributes ->> 'inspection_id' from erp.document d where d.id = v_cn) = v_ins::text
          and (erp.supplier_return(v_cn) ->> 'rma') = 'RMA-99'
          and v_err like 'CLOVEERP_NOT_A_REJECTED_RECEIPT:%'
          and v_err2 like 'CLOVEERP_NOT_A_REJECTED_RECEIPT:%';
    detail := coalesce(v_state, left(format('%s; %s | %s', v_ret, v_err, v_err2), 600));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzsro-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, a2, s_buy, s_fin))
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzsro rolled back with its orders, returns, replacements and bills');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_SUPPLIER_RETURN_OUTCOME_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.supplier_return_outcome_suite() from public, anon;

comment on function erp_test.supplier_return_outcome_suite() is
  'Goods go back to the supplier (20261004910000): a credit note pays the bill it credits as it is '
  'issued, or the order''s next bill, or a bill Finance chooses, refused by name where it may not; a '
  'return for replacement credits nothing, goes through goods received not invoiced, stays off the VAT '
  'return and receives the replacement against itself; a rejection at inspection goes back once.';

create or replace function erp_test.assert_supplier_return_outcome_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.supplier_return_outcome_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_SUPPLIER_RETURN_OUTCOME_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A supplier would be paid for goods they took back, or a replacement would leave the ledger. Read the case that failed.';
  end if;
  if v_total <> 11 then
    raise exception 'CLOVEERP_SUPPLIER_RETURN_OUTCOME_SUITE_SHRANK: % case(s), expected 11', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('supplier return outcomes: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_supplier_return_outcome_suite() from public, anon;

comment on function erp_test.assert_supplier_return_outcome_suite() is
  'Goods sent back to a supplier are credited against the bill or replaced through goods received not '
  'invoiced, without paying the supplier for what they took back (20261004910000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- F. The words the screens say
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Goods sent back to a supplier, for credit or replacement (20261004910000).'
  from (values
    ('What for'),
    ('Credit: the supplier gives the money back. Replacement: they send the same goods again, and nothing is credited.'),
    ('Credit'),
    ('Replacement'),
    ('Their return authorisation'),
    ('RMA-1234'),
    ('Optional. The number the supplier gave for this return.'),
    ('Sent back for a replacement'),
    ('The supplier sends the same goods again. Nothing is credited; the replacement is received here, against this return.'),
    ('Still awaited'),
    ('Receive the replacement'),
    ('Receive the goods the supplier sent again'),
    ('A goods receipt against this return, posted as it is made. The goods go back on the shelf and nothing is billed.'),
    ('Quantity'),
    ('Leave empty to receive everything still awaited.'),
    ('Receive'),
    ('Credit left'),
    ('Return authorisation'),
    ('Supplier credit notes'),
    ('What suppliers credited for goods sent back that no bill has taken yet, kept on their account until one does.'),
    ('No credit is waiting. A supplier credit note no bill takes lands here, to go against their next bill.'),
    ('Credit note'),
    ('Allocate a supplier credit'),
    ('Pays one of the supplier''s open bills from the credit note. The bill moves to part paid or paid.'),
    ('Leave empty to allocate as much as the credit and the bill allow.'),
    ('{amount} credited by {supplier}'),
    ('Return rejected goods to the supplier'),
    ('Sends back what an inspection of a goods receipt rejected, as much as was inspected and is still here, as a draft supplier credit note.'),
    ('Rejected inspection'),
    ('The supplier credits it, or sends the goods again.')
  ) as v(text)
on conflict (key, locale) do nothing;

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
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
