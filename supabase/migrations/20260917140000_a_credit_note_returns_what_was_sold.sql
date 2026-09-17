-- =============================================================================
-- A credit note returns what was sold
--
-- Nobody could give money back. Not on either side. The spine has carried the
-- base type `credit_reference` since 0025 and an A4 template for it since
-- 20260904170000; `return_to_supplier` has had a base type since 0025, a
-- movement type since 0024 and an authorisation mapping since 20260829350000.
-- No installer has ever turned any of it into a document type an organisation
-- holds, so the product could invoice a customer and could not credit one, and
-- could receive a supplier's goods and could not send them back.
-- erp.raise_customer_return() has recorded a request for a credit since
-- 20260829280000, in one row, with two columns named return_document_id and
-- credit_document_id that nothing in the repository has ever written.
--
-- This builds both credit notes. They are close to mirror images, and the half
-- of the work that is not mirrored — how goods come back at what they cost —
-- is shared, so they are one migration.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Stock returns at original cost, not at sale price
--
-- This is the part that is easy to get plausibly wrong. erp.post_document_stock
-- costs an inbound line with
--
--     erp.receive_cost(ln.item_id, d.site_id, ln.quantity,
--                      coalesce(ln.unit_price_minor, 0), ...)
--
-- — the line's own price. That is right for a goods receipt, where the price on
-- the line is what the supplier charged and therefore what the stock cost. It
-- is wrong for goods coming back from a customer, where the price on the line
-- is what we sold them for. Left alone, a credit note would have written the
-- margin into inventory: sell at £25, take it back at £25, and the balance
-- sheet carries £15 of profit as if it were goods.
--
-- The exact cost of what went out is recorded, once, and only once:
-- erp.stock_movement.cost_minor, stamped by t_stock_movement_cost from what
-- erp.issue_cost() actually took out of the costing store. There is no record
-- anywhere of WHICH valuation layers an issue consumed — FIFO consumption is a
-- destructive `update ... set remaining = remaining - v_take` — so cost_minor
-- is the only durable answer, and it is the right one.
--
-- So a credit note line names the line it reverses, in erp.document_relation
-- with relation_kind 'returns', and erp.returned_line_unit_cost_minor() reads
-- the despatch's own movement back through that link. The bridge's inbound
-- branch prefers that answer to the line's price. Every despatch in the product
-- goes through erp.post_document_stock(), which is the only writer that stamps
-- document_line_id, so the link always lands on a movement.
--
-- What it can and cannot promise, said plainly:
--
--   * A full return is exact to the penny of what the despatch took.
--   * A partial return takes its proportional share, rounded once —
--     round(cost_minor / quantity) as the unit cost. Under FIFO a despatch that
--     consumed three layers at three prices has already been flattened to one
--     weighted figure by the time it reaches cost_minor, so the returned goods
--     re-enter as one layer at that weighted cost. The original layer split is
--     not recoverable, by anybody, because nothing ever wrote it down. This is
--     a real limitation and it is stated on the screen as well as here: a
--     partial return is valued at the average of what the despatch cost, not at
--     the cost of the particular units that came back.
--   * A line that names no despatch is refused
--     (CLOVEERP_CREDIT_LINE_HAS_NO_DESPATCH) rather than valued at its price.
--     Returning goods at a guess is the defect; refusing is not.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- A credit note moves stock, so its base type has to say so
--
-- erp_ref.document_type.credit_reference was seeded affects_stock false — a
-- credit note is money, and the goods are somebody else's problem. The spine
-- gave the customer's returned goods no document of their own, so there is no
-- somebody else. This flips the flag, and requires_site with it, because
-- erp.post_document_stock() refuses a stock document with no site and the
-- refusal is better raised when the document is opened than when it is posted.
--
-- The flip is inert today: no installer has ever created a document type on
-- credit_reference, so there is nothing for it to change until the type this
-- migration installs arrives. What it costs is that a credit note in this
-- product returns goods. A credit that moves money only — an overcharge, a
-- settlement discount — is not built, and erp.assert_no_dead_configuration()
-- will now ask any credit_reference type for a movement type.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Two permissions the stock bridge got wrong, and nothing could notice
--
-- erp.post_document_stock() decides who may move the stock with
--
--     case when mt.direction = 'in' then 'procurement.receive'
--          else 'sales.despatch' end
--
-- which is a statement that everything inbound is a purchase and everything
-- outbound is a sale. Both return movement types break it: return_to_supplier
-- is outbound and would have demanded sales.despatch from a buyer, and
-- return_from_customer is inbound and would have demanded procurement.receive
-- from whoever credits a customer. Under the base pack's role library no role
-- holds the pair, so neither credit note could have been posted by anybody.
-- The case now asks the movement type's module as well as its direction. It
-- changes the answer for exactly those two types, and nothing used either.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- The two postings, and why each account is the one it is
--
-- Customer credit note. The exact mirror of the two postings it reverses —
-- sales_invoice (CR revenue at document_value, CR tax control at document_tax,
-- DR receivable balancing) and delivery (DR cost of sales at stock_cost, CR
-- inventory at stock_cost):
--
--   DR revenue          document_value   the supply, unmade
--   DR tax control      document_tax     the tax on it, unmade
--   DR inventory        stock_cost       back on the shelf at what it cost
--   CR cost of sales    stock_cost       the cost of that sale, unmade
--   CR trade receivable balancing        what the customer no longer owes
--
-- The receivable is the balancing line for the same reason it is on the invoice:
-- what the customer owes is not a third measurement, it is what was earned plus
-- what was collected for the state. The two stock_cost lines net to nothing, so
-- they do not reach it. erp.posting_rule_imbalance() short-circuits on the one
-- balancing line, and the bridge orders non-balancing lines first, so the
-- receivable is computed as document_value + document_tax exactly.
--
-- Supplier credit note. The brief asks whether the credit goes to inventory or
-- to goods received not invoiced, "depending on whether the original was
-- invoiced". A posting rule cannot branch on that, and it does not have to,
-- because the honest answer is both. The receipt posted DR inventory at
-- stock_cost / CR GRNI balancing; the purchase invoice posted DR GRNI at
-- document_value / DR tax control at document_tax / CR payable balancing. One
-- rule unwinds both:
--
--   DR goods received not invoiced   stock_cost       the receipt, unmade
--   CR inventory                     stock_cost       the goods, off the shelf
--   CR goods received not invoiced   document_value   the invoice, unmade
--   CR tax control                   document_tax     the tax on it, unmade
--   DR trade payable                 balancing        what we no longer owe
--
-- GRNI nets to (stock_cost - document_value), which is the difference between
-- what the goods are carried at and what the supplier is crediting — precisely
-- the figure GRNI already holds on the way in under standard costing, left in
-- the same place rather than invented into a variance account the chart may not
-- have. Where the two agree, as they do under average and FIFO costing when the
-- return is priced from the receipt, the two GRNI lines cancel and the credit
-- note posts inventory against payables, which is what a person would draw.
-- Both zero lines are skipped by 20260910165931 in that case.
--
-- Return ten of a hundred received at £10: DR GRNI 100, CR inventory 100,
-- CR GRNI 100, DR payable 100. Stock down £100, payables down £100, GRNI flat.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What this does not do
--
-- Input tax is not credited back. erp.determine_document_tax() determines tax
-- for a sales invoice or a sales credit and deliberately not for a purchase,
-- because what another company charged is that company's statement and ours to
-- transcribe (20260916320000). A supplier credit note therefore carries no tax
-- and its tax control line posts nothing; the line stays in the rule so that a
-- transcribed figure would reach the ledger the day there is one. The customer
-- credit note does reverse its tax, by the same route the invoice determined it.
--
-- A credit for anything other than goods — an overcharge, a price adjustment, a
-- settlement — cannot be raised. Both types move stock for every line they
-- carry. That is the honest consequence of giving the returned goods no
-- document of their own, and it is what the two DoD cases ask for.
--
-- Proof: erp_test.credit_note_suite() (18 cases), which builds its own site,
-- supplier, customer and products, receives a hundred at a cost, sells ten at a
-- price, credits them back, and reads the ledger and the valuation layer.
-- =============================================================================

-- ── 1. A credit note moves stock ─────────────────────────────────────────────

update erp_ref.document_type
   set affects_stock = true,
       requires_site = true,
       description = 'The operational side of a credit, and the goods that came '
                     'back with it.'
 where code = 'credit_reference';

-- ── 2. What the despatch cost, read back through the link ────────────────────

create or replace function erp.returned_line_unit_cost_minor(p_line_id uuid)
returns bigint
language sql
stable
security invoker
set search_path = ''
as $$
  -- The unit cost of the movement this line reverses. erp.stock_movement is the
  -- only durable record of what an issue took out of the costing store, and
  -- erp.post_document_stock() is the only writer that stamps document_line_id,
  -- so a line linked to a despatch line always finds its movement.
  --
  -- cost_minor is null on rows written before 20260906050000 and on stock the
  -- company does not own; the coalesce is the same one erp.document_stock_cost_minor()
  -- has always used. Reversals are excluded because erp.reverse_stock_movement()
  -- copies document_line_id on to the mirror row and re-rounds its cost.
  select round(coalesce(m.cost_minor,
                        round(m.quantity * m.unit_cost_minor))::numeric
               / nullif(m.quantity, 0))::bigint
    from erp.document_relation r
    join erp.stock_movement m
      on m.tenant_id = r.tenant_id
     and m.document_line_id = r.to_line_id
     and not m.is_reversal
     and m.unit_cost_minor is not null
   where r.tenant_id = erp.current_tenant_id()
     and r.from_line_id = p_line_id
     and r.relation_kind = 'returns'
   order by m.id
   limit 1
$$;

revoke all on function erp.returned_line_unit_cost_minor(uuid) from public, anon, authenticated;

comment on function erp.returned_line_unit_cost_minor(uuid) is
  'What one unit of the movement this line reverses actually cost, read from '
  'erp.stock_movement.cost_minor through the ''returns'' link the credit note '
  'wrote. Null where the line names no despatch, which is a refusal and not a '
  'reason to guess.';

-- ── 3. The bridge prefers what it cost to what it sold for ───────────────────

-- The body is needled rather than re-emitted: 20260905010000 put occurred_at
-- into it, 20260906060000 the consignment test and the site-location call, and
-- 20260906142000 the receipt inspection. Re-emitting from any file would drop
-- all three, so each is asserted still present afterwards.
do $bridge$
declare
  v_sig constant text := 'erp.post_document_stock(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_cost constant text :=
       E'        coalesce(ln.unit_price_minor, 0), coalesce(ln.currency, d.currency),\n'
    || E'        ln.batch_id, null);';
  v_perm constant text :=
    E'    case when mt.direction = ''in'' then ''procurement.receive'' else ''sales.despatch'' end,';
  v_new text;
begin
  if (length(v_def) - length(replace(v_def, v_cost, ''))) / length(v_cost) <> 1 then
    raise exception 'CLOVEERP_BRIDGE_UNRECOGNISED: the inbound costing call in % is not the one this migration changes', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_perm, ''))) / length(v_perm) <> 1 then
    raise exception 'CLOVEERP_BRIDGE_UNRECOGNISED: the movement permission in % is not the one this migration changes', v_sig;
  end if;

  v_new := replace(v_def, v_cost,
       E'        coalesce(erp.returned_line_unit_cost_minor(ln.id),\n'
    || E'                 ln.unit_price_minor, 0), coalesce(ln.currency, d.currency),\n'
    || E'        ln.batch_id, null);');

  v_new := replace(v_new, v_perm,
       E'    -- Direction alone said everything inbound is a purchase and\n'
    || E'    -- everything outbound is a sale. The two return movement types are\n'
    || E'    -- neither, and no seeded role holds the permission the old answer\n'
    || E'    -- demanded of them. Only those two types change answer here.\n'
    || E'    case when mt.module_code = ''sales'' and mt.direction = ''in'' then ''sales.invoice''\n'
    || E'         when mt.module_code = ''procurement'' and mt.direction = ''out'' then ''procurement.order''\n'
    || E'         when mt.direction = ''in'' then ''procurement.receive''\n'
    || E'         else ''sales.despatch'' end,');

  execute v_new;

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('erp.ensure_site_location(d.site_id)' in v_def) = 0
     or position('if not v_owned then' in v_def) = 0
     or position('occurred_at' in v_def) = 0
     or position('quarantine_on_receipt' in v_def) = 0 then
    raise exception 'CLOVEERP_BRIDGE_PATCH_LOST: % no longer carries a patch it had before this migration', v_sig;
  end if;
end
$bridge$;

-- ── 4. Raising a credit note ─────────────────────────────────────────────────

create or replace function erp.raise_customer_credit_note(
  p_document_id uuid,
  p_reason_code text,
  p_reason      text  default null,
  p_lines       jsonb default null
) returns uuid
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_base   text;
  v_site   uuid;
  v_cn     uuid;
  v_line   uuid;
  v_out    numeric;
  v_n      integer := 0;
  v_ret    uuid;
  ln       record;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_document_id
      using errcode = '23503',
            hint = 'Open the delivery or the invoice you mean to credit, and raise the credit note from it.';
  end if;

  select bt.code into v_base
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.tenant_id = v_tenant and dt.id = d.document_type_id;

  if coalesce(v_base, '') not in ('delivery', 'invoice_reference') then
    raise exception
      'CLOVEERP_CREDIT_SOURCE_NOT_CREDITABLE: % is a %, and a credit note is '
      'raised against the despatch or the invoice it reverses', d.document_number, v_base
      using errcode = '23514';
  end if;

  if coalesce(btrim(p_reason_code), '') = '' then
    raise exception
      'CLOVEERP_CREDIT_NEEDS_A_REASON: a credit note without a reason code '
      'cannot be analysed, and analysing them is the only way returns go down'
      using errcode = '23514';
  end if;

  -- The permission that raises an invoice raises the credit that reverses it.
  perform erp.authorise('sales.invoice', d.entity_id, d.site_id, null,
                        'document', p_document_id);

  -- The goods come back to the site they left. An invoice need not name one, so
  -- the despatch it billed is asked.
  v_site := coalesce(d.site_id, (
    select gd.site_id
      from erp.document_line sl
      join erp.document_relation r
        on r.tenant_id = sl.tenant_id and r.from_line_id = sl.id
       and r.relation_kind = 'invoices'
      join erp.document_line gl on gl.tenant_id = sl.tenant_id and gl.id = r.to_line_id
      join erp.document gd on gd.tenant_id = gl.tenant_id and gd.id = gl.document_id
     where sl.tenant_id = v_tenant and sl.document_id = p_document_id
       and gd.site_id is not null
     limit 1));

  if v_site is null then
    raise exception
      'CLOVEERP_CREDIT_NEEDS_A_SITE: % names no site and neither does the '
      'despatch it billed, so there is nowhere for the goods to come back to',
      d.document_number
      using errcode = '23502';
  end if;

  v_cn := erp.open_document('sales_credit_note', d.party_id, d.entity_id, v_site,
                            d.document_number, null, d.currency);

  for ln in
    select sl.id            as source_line_id,
           sl.line_no       as line_no,
           coalesce(gr.to_line_id,
                    case when v_base = 'delivery' then sl.id end) as goods_line_id,
           sl.item_id, sl.description, sl.unit_price_minor, sl.uom_id,
           sl.quantity      as sold,
           coalesce((select (e.value ->> 'quantity')::numeric
                       from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e
                      where (e.value ->> 'line_id')::uuid = sl.id),
                    sl.quantity) as qty
      from erp.document_line sl
      left join erp.document_relation gr
        on gr.tenant_id = sl.tenant_id and gr.from_line_id = sl.id
       and gr.relation_kind = 'invoices'
     where sl.tenant_id = v_tenant
       and sl.document_id = p_document_id
       and not coalesce(sl.is_cancelled, false)
       and sl.quantity > 0
       and (p_lines is null
            or exists (select 1 from jsonb_array_elements(p_lines) e
                        where (e.value ->> 'line_id')::uuid = sl.id))
     order by sl.line_no
  loop
    if ln.goods_line_id is null then
      raise exception
        'CLOVEERP_CREDIT_LINE_HAS_NO_DESPATCH: line % of % reaches no despatch, '
        'so what the goods cost is unknown', ln.line_no, d.document_number
        using errcode = '23503';
    end if;

    if coalesce(ln.qty, 0) <= 0 then
      continue;
    end if;

    -- What is still out there: what went out, less what has already come back
    -- on an earlier credit note.
    select gl.quantity - coalesce((
             select sum(rr.quantity) from erp.document_relation rr
              where rr.tenant_id = v_tenant and rr.to_line_id = gl.id
                and rr.relation_kind = 'returns'), 0)
      into v_out
      from erp.document_line gl
     where gl.tenant_id = v_tenant and gl.id = ln.goods_line_id;

    if ln.qty > coalesce(v_out, 0) then
      raise exception
        'CLOVEERP_CREDIT_EXCEEDS_WHAT_WENT_OUT: line % credits % but only % is '
        'still out', ln.line_no, ln.qty, coalesce(v_out, 0)
        using errcode = '23514';
    end if;

    v_line := erp.add_document_line(v_cn, ln.item_id, ln.qty,
                                    coalesce(ln.unit_price_minor, 0),
                                    ln.description);

    -- The batch travels with the goods; a batch-controlled item refuses a
    -- movement without one, and the batch that comes back is the one that went.
    update erp.document_line cl
       set batch_id = gl.batch_id,
           uom_id   = coalesce(gl.uom_id, cl.uom_id),
           updated_at = now()
      from erp.document_line gl
     where cl.tenant_id = v_tenant and cl.id = v_line
       and gl.tenant_id = v_tenant and gl.id = ln.goods_line_id;

    -- The link the costing reads back through, and the lineage the document
    -- screen already draws.
    insert into erp.document_relation (
      tenant_id, from_document_id, to_document_id, relation_kind,
      from_line_id, to_line_id, quantity)
    select v_tenant, v_cn, gl.document_id, 'returns', v_line, gl.id, ln.qty
      from erp.document_line gl
     where gl.tenant_id = v_tenant and gl.id = ln.goods_line_id
    on conflict do nothing;

    v_n := v_n + 1;
  end loop;

  if v_n = 0 then
    raise exception
      'CLOVEERP_CREDIT_HAS_NO_LINES: nothing on % was chosen to credit',
      d.document_number
      using errcode = '23514';
  end if;

  -- A credit raised on an invoice says so, so the invoice's own lineage shows
  -- what reversed it.
  if v_base = 'invoice_reference' then
    insert into erp.document_relation (
      tenant_id, from_document_id, to_document_id, relation_kind)
    values (v_tenant, v_cn, p_document_id, 'credits')
    on conflict do nothing;
  end if;

  -- erp.customer_return has carried return_document_id and credit_document_id
  -- since 20260829280000 and nothing has ever written either. A return already
  -- asked for takes them; otherwise the credit note records its own. In this
  -- product one document is both, because the goods and the money come back
  -- together; the columns stay two because a return that only takes goods back,
  -- and a credit that only moves money, would each fill one.
  select cr.id into v_ret
    from erp.customer_return cr
   where cr.tenant_id = v_tenant
     and cr.original_document_id = p_document_id
     and cr.status = 'open'
     -- Neither document raised yet: the two columns are read here to decide
     -- which open return this credit note belongs to, which is the first time
     -- anything in the product has read either of them.
     and cr.return_document_id is null
     and cr.credit_document_id is null
   order by cr.created_at
   limit 1;

  if v_ret is not null then
    update erp.customer_return
       set return_document_id = v_cn, credit_document_id = v_cn,
           status = 'credited', updated_at = now()
     where tenant_id = v_tenant and id = v_ret;
  else
    insert into erp.customer_return (
      tenant_id, entity_id, site_id, party_id, original_document_id,
      reason_code, reason, outcome,
      return_document_id, credit_document_id, status)
    values (v_tenant, d.entity_id, v_site, d.party_id, p_document_id,
            btrim(p_reason_code), p_reason, 'credit', v_cn, v_cn, 'credited');
  end if;

  return v_cn;
end;
$$;

comment on function erp.raise_customer_credit_note(uuid, text, text, jsonb) is
  'A credit note against a despatch or the invoice that billed it: the customer '
  'owes less, revenue reverses, and the goods come back on to the shelf at what '
  'they cost rather than at what they sold for. Left in draft; issuing it posts.';

create or replace function erp.raise_supplier_credit_note(
  p_document_id uuid,
  p_reason_code text,
  p_reason      text  default null,
  p_lines       jsonb default null
) returns uuid
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_base   text;
  v_cn     uuid;
  v_line   uuid;
  v_out    numeric;
  v_n      integer := 0;
  v_order  uuid;
  ln       record;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_document_id
      using errcode = '23503',
            hint = 'Open the goods receipt you mean to return against, and raise the credit note from it.';
  end if;

  select bt.code into v_base
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.tenant_id = v_tenant and dt.id = d.document_type_id;

  if coalesce(v_base, '') <> 'receipt' then
    raise exception
      'CLOVEERP_CREDIT_SOURCE_NOT_CREDITABLE: % is a %, and goods go back '
      'against the receipt that brought them in', d.document_number, v_base
      using errcode = '23514';
  end if;

  if coalesce(btrim(p_reason_code), '') = '' then
    raise exception
      'CLOVEERP_CREDIT_NEEDS_A_REASON: a credit note without a reason code '
      'cannot be analysed, and analysing them is the only way returns go down'
      using errcode = '23514';
  end if;

  -- Sending goods back to a supplier is a buying decision, which is the
  -- permission erp_ref.document_type already gives return_to_supplier.
  perform erp.authorise('procurement.order', d.entity_id, d.site_id, null,
                        'document', p_document_id);

  if d.site_id is null then
    raise exception
      'CLOVEERP_CREDIT_NEEDS_A_SITE: % names no site, so there is nowhere for '
      'the goods to leave from', d.document_number
      using errcode = '23502';
  end if;

  v_cn := erp.open_document('purchase_credit_note', d.party_id, d.entity_id,
                            d.site_id, d.document_number, null, d.currency);

  for ln in
    select rl.id as goods_line_id, rl.line_no, rl.item_id, rl.description,
           rl.unit_price_minor, rl.uom_id, rl.batch_id, rl.quantity as received,
           coalesce((select (e.value ->> 'quantity')::numeric
                       from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e
                      where (e.value ->> 'line_id')::uuid = rl.id),
                    rl.quantity) as qty
      from erp.document_line rl
     where rl.tenant_id = v_tenant
       and rl.document_id = p_document_id
       and not coalesce(rl.is_cancelled, false)
       and rl.quantity > 0
       and (p_lines is null
            or exists (select 1 from jsonb_array_elements(p_lines) e
                        where (e.value ->> 'line_id')::uuid = rl.id))
     order by rl.line_no
  loop
    if coalesce(ln.qty, 0) <= 0 then
      continue;
    end if;

    v_out := ln.received - coalesce((
      select sum(rr.quantity) from erp.document_relation rr
       where rr.tenant_id = v_tenant and rr.to_line_id = ln.goods_line_id
         and rr.relation_kind = 'returns'), 0);

    if ln.qty > coalesce(v_out, 0) then
      raise exception
        'CLOVEERP_CREDIT_EXCEEDS_WHAT_WENT_OUT: line % returns % but only % of '
        'what arrived is still here', ln.line_no, ln.qty, coalesce(v_out, 0)
        using errcode = '23514';
    end if;

    v_line := erp.add_document_line(v_cn, ln.item_id, ln.qty,
                                    coalesce(ln.unit_price_minor, 0),
                                    ln.description);

    update erp.document_line cl
       set batch_id = ln.batch_id,
           uom_id   = coalesce(ln.uom_id, cl.uom_id),
           updated_at = now()
     where cl.tenant_id = v_tenant and cl.id = v_line;

    insert into erp.document_relation (
      tenant_id, from_document_id, to_document_id, relation_kind,
      from_line_id, to_line_id, quantity)
    values (v_tenant, v_cn, p_document_id, 'returns', v_line, ln.goods_line_id, ln.qty)
    on conflict do nothing;

    v_n := v_n + 1;
  end loop;

  if v_n = 0 then
    raise exception
      'CLOVEERP_CREDIT_HAS_NO_LINES: nothing on % was chosen to return',
      d.document_number
      using errcode = '23514';
  end if;

  -- The order's history shows the return. erp.document_lineage() walks the
  -- graph both ways, so a link from the credit note to the order the receipt
  -- fulfilled is what puts the return on the purchase order's own screen.
  select r.to_document_id into v_order
    from erp.document_relation r
   where r.tenant_id = v_tenant
     and r.from_document_id = p_document_id
     and r.relation_kind in ('fulfils', 'converts')
   order by r.created_at
   limit 1;

  if v_order is not null then
    insert into erp.document_relation (
      tenant_id, from_document_id, to_document_id, relation_kind)
    values (v_tenant, v_cn, v_order, 'returns')
    on conflict do nothing;
  end if;

  return v_cn;
end;
$$;

comment on function erp.raise_supplier_credit_note(uuid, text, text, jsonb) is
  'A credit note against a goods receipt: the goods leave at what they cost, '
  'what we owe the supplier goes down by what they are crediting, and the '
  'purchase order''s history shows the return. Left in draft; issuing it posts.';

-- ── 5. The doors ─────────────────────────────────────────────────────────────

create or replace function public.erp_raise_customer_credit_note(
  p_document_id uuid,
  p_reason_code text,
  p_reason      text  default null,
  p_lines       jsonb default null)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_id uuid := erp.raise_customer_credit_note(p_document_id, p_reason_code, p_reason, p_lines);
begin
  return (select jsonb_build_object(
            'document_id', d.id,
            'document_number', d.document_number,
            'lines', (select count(*) from erp.document_line l
                       where l.tenant_id = d.tenant_id and l.document_id = d.id))
            from erp.document d
           where d.tenant_id = erp.current_tenant_id() and d.id = v_id);
end;
$$;

revoke all on function public.erp_raise_customer_credit_note(uuid, text, text, jsonb) from public, anon;
grant execute on function public.erp_raise_customer_credit_note(uuid, text, text, jsonb) to authenticated, service_role;

comment on function public.erp_raise_customer_credit_note(uuid, text, text, jsonb) is
  'Raises a credit note against a despatch or the invoice that billed it, in draft.';

create or replace function public.erp_raise_supplier_credit_note(
  p_document_id uuid,
  p_reason_code text,
  p_reason      text  default null,
  p_lines       jsonb default null)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_id uuid := erp.raise_supplier_credit_note(p_document_id, p_reason_code, p_reason, p_lines);
begin
  return (select jsonb_build_object(
            'document_id', d.id,
            'document_number', d.document_number,
            'lines', (select count(*) from erp.document_line l
                       where l.tenant_id = d.tenant_id and l.document_id = d.id))
            from erp.document d
           where d.tenant_id = erp.current_tenant_id() and d.id = v_id);
end;
$$;

revoke all on function public.erp_raise_supplier_credit_note(uuid, text, text, jsonb) from public, anon;
grant execute on function public.erp_raise_supplier_credit_note(uuid, text, text, jsonb) to authenticated, service_role;

comment on function public.erp_raise_supplier_credit_note(uuid, text, text, jsonb) is
  'Raises a credit note against a goods receipt, in draft, with the goods on it.';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_raise_customer_credit_note', 'erp.authorise',
   'Raises a sales credit note in draft against the despatch or invoice it '
   'reverses, under sales.invoice — the permission that raised the invoice in '
   'the first place. It writes erp.document, erp.document_line, '
   'erp.document_relation and erp.customer_return; nothing posts until the '
   'credit note is issued, which is a transition with its own guard.'),
  ('erp_raise_supplier_credit_note', 'erp.authorise',
   'Raises a purchase credit note in draft against the goods receipt it '
   'reverses, under procurement.order — the permission erp_ref.document_type '
   'already gives the return_to_supplier base type. It writes erp.document, '
   'erp.document_line and erp.document_relation; nothing leaves the shelf until '
   'the credit note is issued.')
on conflict (function_name) do update set gate = excluded.gate,
                                          rationale = excluded.rationale;

-- ── 6. What the refusals mean ────────────────────────────────────────────────

select erp.register_refusal(
  'CLOVEERP_CREDIT_SOURCE_NOT_CREDITABLE',
  'Raising a credit note against a document that never moved any goods.',
  'A credit note in this product gives the money back and takes the goods back at the same time, so it has to start from the document that moved them: a despatch or the invoice that billed one on the sales side, a goods receipt on the buying side. Started anywhere else there is nothing to value the returned goods at.',
  'Open the delivery, the sales invoice or the goods receipt the goods went out on or came in on, and raise the credit note from there.');

select erp.register_refusal(
  'CLOVEERP_CREDIT_NEEDS_A_REASON',
  'A credit note raised with no reason code on it.',
  'Returns only ever go down when somebody can say which reason is costing the most, and a return with no reason code is invisible to that report however carefully the note beside it was written.',
  'Choose a reason code on the credit note. Add the code your organisation uses on the Configuration screen if the list is missing one.');

select erp.register_refusal(
  'CLOVEERP_CREDIT_LINE_HAS_NO_DESPATCH',
  'Crediting a line whose goods cannot be traced back to the despatch that sent them out.',
  'Goods come back on to the shelf at what they cost, and the only record of what a despatch cost is the movement it wrote. A line that reaches no despatch could only be valued at what it sold for, which would put the margin into inventory and show profit as though it were stock.',
  'Credit the delivery itself rather than the invoice, or credit the invoice lines that were raised from a delivery. A line typed straight on to an invoice has no despatch behind it and cannot bring goods back.');

select erp.register_refusal(
  'CLOVEERP_CREDIT_EXCEEDS_WHAT_WENT_OUT',
  'Crediting back more than was sent out, or returning more than arrived.',
  'What is still out is what the despatch or the receipt moved, less anything an earlier credit note has already brought back. Crediting more than that would put stock on the shelf that never left it and money back that was never charged.',
  'Reduce the quantity to what is still out, or check whether an earlier credit note already covered some of it on the document history.');

select erp.register_refusal(
  'CLOVEERP_CREDIT_NEEDS_A_SITE',
  'Raising a credit note when neither the document nor the despatch behind it names a site.',
  'A credit note moves goods, and goods are somewhere. Without a site there is nowhere for them to come back to or leave from, and the movement could not be written at all.',
  'Raise the credit note from the delivery or the goods receipt, which always names its site.');

select erp.register_refusal(
  'CLOVEERP_CREDIT_HAS_NO_LINES',
  'A credit note raised with no lines chosen on it.',
  'A credit note with no lines credits nothing, moves nothing, and would sit in the list as a document nobody can finish or explain.',
  'Choose at least one line to credit, or leave the lines unchosen to credit the whole document.');

-- ── 7. The installers, so a new organisation has both ────────────────────────

-- Appended to the array erp.install_module_config() is given, in apply order:
-- the lifecycle and the rule first, then the sequence, then the type that names
-- all three — erp.upsert_document_type() refuses a sequence that is not there
-- yet, and the promoter orders these kinds by seq alone.
do $sales$
declare
  v_def text := pg_get_functiondef('erp.configure_sales(numeric,text)'::regprocedure);
  v_needle constant text :=
       E'          ''numbering_rule'',''sales_invoice'',''state_machine'',''sales_invoice'',\n'
    || E'          ''posting_rule'',''sales_invoice''))));';
  v_new text;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_SALES_INSTALLER_UNRECOGNISED: the sales invoice document type in erp.configure_sales() is not the last item this migration appends to';
  end if;

  v_new := replace(v_def, v_needle,
       E'          ''numbering_rule'',''sales_invoice'',''state_machine'',''sales_invoice'',\n'
    || E'          ''posting_rule'',''sales_invoice'')),\n'
    || E'\n'
    || E'      -- A credit note is raised, and either issued or abandoned. Issuing\n'
    || E'      -- it is the tax point, the moment the receivable falls, and the\n'
    || E'      -- moment the goods are back on the shelf.\n'
    || E'      jsonb_build_object(''kind'',''state_machine'',''key'',''sales_credit_note'',''payload'',\n'
    || E'        jsonb_build_object(\n'
    || E'          ''code'',''sales_credit_note'',''object_type'',''document'',''name'',''Credit note'',\n'
    || E'          ''states'', jsonb_build_array(\n'
    || E'            jsonb_build_object(''code'',''draft'',''name'',''Draft'',''is_initial'',true,''sort_order'',10),\n'
    || E'            jsonb_build_object(''code'',''issued'',''name'',''Issued'',''is_terminal'',true,''is_committed'',true,''sort_order'',20),\n'
    || E'            jsonb_build_object(''code'',''cancelled'',''name'',''Cancelled'',''is_terminal'',true,''sort_order'',90)),\n'
    || E'          ''transitions'', jsonb_build_array(\n'
    || E'            jsonb_build_object(''code'',''issue'',''name'',''Issue'',''from'',''draft'',''to'',''issued'',''required_permission'',''sales.invoice''),\n'
    || E'            jsonb_build_object(''code'',''cancel'',''name'',''Cancel'',''from'',''draft'',''to'',''cancelled'',''required_permission'',''sales.invoice'')))),\n'
    || E'\n'
    || E'      -- The mirror of the sales invoice and of the delivery, in one rule.\n'
    || E'      -- The two stock lines net to nothing, so the receivable — the\n'
    || E'      -- balancing line, as it is on the invoice — is the net plus the tax\n'
    || E'      -- and nothing else.\n'
    || E'      jsonb_build_object(''kind'',''posting_rule'',''key'',''sales_credit_note'',''payload'',\n'
    || E'        jsonb_build_object(\n'
    || E'          ''code'',''sales_credit_note'',''name'',''Customer credit note'',''ledger'',''GL'',\n'
    || E'          ''event_type'',''document.credit_note.posted'',\n'
    || E'          ''posting_lines'', jsonb_build_array(\n'
    || E'            jsonb_build_object(''account'', erp.tenant_account_code(''revenue''),''side'',''debit'',\n'
    || E'                               ''basis'',''document_value'',''rate'',1,\n'
    || E'                               ''description'',''Revenue reversed''),\n'
    || E'            jsonb_build_object(''account'', erp.tenant_account_code(''tax_control''),''side'',''debit'',\n'
    || E'                               ''basis'',''document_tax'',''rate'',1,\n'
    || E'                               ''description'',''Tax on the credit''),\n'
    || E'            jsonb_build_object(''account'', erp.tenant_account_code(''inventory''),''side'',''debit'',\n'
    || E'                               ''basis'',''stock_cost'',''rate'',1,\n'
    || E'                               ''description'',''Goods back on the shelf, at what they cost''),\n'
    || E'            jsonb_build_object(''account'', erp.tenant_account_code(''cost_of_sales''),''side'',''credit'',\n'
    || E'                               ''basis'',''stock_cost'',''rate'',1,\n'
    || E'                               ''description'',''Cost of that sale, reversed''),\n'
    || E'            jsonb_build_object(''account'', erp.tenant_account_code(''trade_receivable''),''side'',''credit'',\n'
    || E'                               ''balancing'',true,\n'
    || E'                               ''description'',''What the customer no longer owes'')))),\n'
    || E'\n'
    || E'      jsonb_build_object(''kind'',''numbering_rule'',''key'',''sales_credit_note'',''payload'',\n'
    || E'        jsonb_build_object(''code'',''sales_credit_note'',''entity'',v_entity_code,\n'
    || E'          ''prefix'',''CN-'',''pad_to'',6,''reset_period'',''yearly'',''next_value'',1)),\n'
    || E'\n'
    || E'      jsonb_build_object(''kind'',''document_type'',''key'',''sales_credit_note'',''payload'',\n'
    || E'        jsonb_build_object(''code'',''sales_credit_note'',''base_type'',''credit_reference'',\n'
    || E'          ''name'',''Credit note'',''entity'',v_entity_code,\n'
    || E'          ''numbering_rule'',''sales_credit_note'',''state_machine'',''sales_credit_note'',\n'
    || E'          ''stock_movement_type'',''return_from_customer'',\n'
    || E'          ''posting_rule'',''sales_credit_note''))));');

  execute v_new;
end
$sales$;

do $proc$
declare
  v_def text := pg_get_functiondef('erp.configure_procurement_controls(text,numeric,numeric,bigint)'::regprocedure);
  v_needle constant text :=
       E'          ''posting_rule'',''purchase_invoice'',\n'
    || E'          ''create_permission'',''procurement.match''))));';
  v_new text;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_PROCUREMENT_CONTROLS_UNRECOGNISED: the purchase invoice document type in erp.configure_procurement_controls() is not the last item this migration appends to';
  end if;

  v_new := replace(v_def, v_needle,
       E'          ''posting_rule'',''purchase_invoice'',\n'
    || E'          ''create_permission'',''procurement.match'')),\n'
    || E'\n'
    || E'      jsonb_build_object(''kind'',''state_machine'',''key'',''purchase_credit_note'',''payload'',\n'
    || E'        jsonb_build_object(\n'
    || E'          ''code'',''purchase_credit_note'',''object_type'',''document'',''name'',''Supplier credit note'',\n'
    || E'          ''states'', jsonb_build_array(\n'
    || E'            jsonb_build_object(''code'',''draft'',''name'',''Draft'',''is_initial'',true,''sort_order'',10),\n'
    || E'            jsonb_build_object(''code'',''issued'',''name'',''Issued'',''is_terminal'',true,''is_committed'',true,''sort_order'',20),\n'
    || E'            jsonb_build_object(''code'',''cancelled'',''name'',''Cancelled'',''is_terminal'',true,''sort_order'',90)),\n'
    || E'          ''transitions'', jsonb_build_array(\n'
    || E'            jsonb_build_object(''code'',''issue'',''name'',''Issue'',''from'',''draft'',''to'',''issued'',''required_permission'',''procurement.order''),\n'
    || E'            jsonb_build_object(''code'',''cancel'',''name'',''Cancel'',''from'',''draft'',''to'',''cancelled'',''required_permission'',''procurement.order'')))),\n'
    || E'\n'
    || E'      -- The receipt and the supplier bill, both unwound. Goods\n'
    || E'      -- received not invoiced takes the difference between what the goods\n'
    || E'      -- are carried at and what the supplier is crediting, which is the\n'
    || E'      -- same place it holds that difference on the way in.\n'
    || E'      jsonb_build_object(''kind'',''posting_rule'',''key'',''purchase_credit_note'',''payload'',\n'
    || E'        jsonb_build_object(\n'
    || E'          ''code'',''purchase_credit_note'',''name'',''Supplier credit note'',''ledger'',''GL'',\n'
    || E'          ''event_type'',''document.supplier_credit_note.posted'',\n'
    || E'          ''posting_lines'', jsonb_build_array(\n'
    || E'            jsonb_build_object(''account'', v_grni,''side'',''debit'',\n'
    || E'                               ''basis'',''stock_cost'',''rate'',1,\n'
    || E'                               ''description'',''The receipt, unmade''),\n'
    || E'            jsonb_build_object(''account'', erp.tenant_account_code(''inventory''),''side'',''credit'',\n'
    || E'                               ''basis'',''stock_cost'',''rate'',1,\n'
    || E'                               ''description'',''The goods, off the shelf at what they cost''),\n'
    || E'            jsonb_build_object(''account'', v_grni,''side'',''credit'',\n'
    || E'                               ''basis'',''document_value'',''rate'',1,\n'
    || E'                               ''description'',''The bill, unmade''),\n'
    || E'            jsonb_build_object(''account'', erp.tenant_account_code(''tax_control''),''side'',''credit'',\n'
    || E'                               ''basis'',''document_tax'',''rate'',1,\n'
    || E'                               ''description'',''Tax the supplier credits back''),\n'
    || E'            jsonb_build_object(''account'', v_ap,''side'',''debit'',\n'
    || E'                               ''balancing'',true,\n'
    || E'                               ''description'',''What we no longer owe'')))),\n'
    || E'\n'
    || E'      jsonb_build_object(''kind'',''numbering_rule'',''key'',''purchase_credit_note'',''payload'',\n'
    || E'        jsonb_build_object(\n'
    || E'          ''code'',''purchase_credit_note'', ''prefix'',''PCN-'', ''pad_to'',6,\n'
    || E'          ''reset_period'',''yearly'', ''next_value'',1,\n'
    || E'          ''entity'',(select e.code from erp.entity e\n'
    || E'                     where e.tenant_id = v_tenant and e.status = ''active''\n'
    || E'                     order by e.code limit 1))),\n'
    || E'\n'
    || E'      jsonb_build_object(''kind'',''document_type'',''key'',''purchase_credit_note'',''payload'',\n'
    || E'        jsonb_build_object(''code'',''purchase_credit_note'',\n'
    || E'          ''base_type'',''return_to_supplier'',''name'',''Supplier credit note'',\n'
    || E'          ''numbering_rule'',''purchase_credit_note'',''state_machine'',''purchase_credit_note'',\n'
    || E'          ''stock_movement_type'',''return_to_supplier'',\n'
    || E'          ''posting_rule'',''purchase_credit_note''))));');

  execute v_new;
end
$proc$;

-- ── 8. And the organisations already configured take it as a change ──────────

update erp_ref.module_installer
   set current_version = 2,
       description = 'Quotation, sales order, delivery and invoice: their states, '
                     'the approvals a discount and a credit exposure require, and '
                     'the despatch that moves stock. Version 2 (20260917100000) '
                     'adds the credit note that reverses an invoice and brings the '
                     'goods back at what they cost.'
 where install_code = 'sales-lifecycle';

update erp_ref.module_installer
   set current_version = 3,
       description = 'The supplier bill, the payment rule and the match tolerances. '
                     'Version 2 (20260916320000) debits the tax a supplier charged to '
                     'the tax control account and makes the payable the gross owed. '
                     'Version 3 (20260917100000) adds the supplier credit note that '
                     'sends goods back and reduces what we owe.'
 where install_code = 'procurement-controls';

insert into erp_ref.module_upgrade_item
  (install_code, to_version, object_kind, object_key, payload, seq)
values
  ('sales-lifecycle', 2, 'state_machine', 'sales_credit_note',
   jsonb_build_object(
     'code', 'sales_credit_note', 'object_type', 'document', 'name', 'Credit note',
     'states', jsonb_build_array(
       jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
       jsonb_build_object('code','issued','name','Issued','is_terminal',true,'is_committed',true,'sort_order',20),
       jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
     'transitions', jsonb_build_array(
       jsonb_build_object('code','issue','name','Issue','from','draft','to','issued','required_permission','sales.invoice'),
       jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','sales.invoice'))),
   100),

  ('sales-lifecycle', 2, 'posting_rule', 'sales_credit_note',
   jsonb_build_object(
     'code', 'sales_credit_note', 'name', 'Customer credit note', 'ledger', 'GL',
     'event_type', 'document.credit_note.posted',
     'posting_lines', jsonb_build_array(
       jsonb_build_object('account', jsonb_build_object('purpose', 'revenue'),
                          'side', 'debit', 'basis', 'document_value', 'rate', 1,
                          'description', 'Revenue reversed'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'tax_control'),
                          'side', 'debit', 'basis', 'document_tax', 'rate', 1,
                          'description', 'Tax on the credit'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'inventory'),
                          'side', 'debit', 'basis', 'stock_cost', 'rate', 1,
                          'description', 'Goods back on the shelf, at what they cost'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'cost_of_sales'),
                          'side', 'credit', 'basis', 'stock_cost', 'rate', 1,
                          'description', 'Cost of that sale, reversed'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'trade_receivable'),
                          'side', 'credit', 'balancing', true,
                          'description', 'What the customer no longer owes'))),
   110),

  ('sales-lifecycle', 2, 'numbering_rule', 'sales_credit_note',
   jsonb_build_object('code', 'sales_credit_note', 'prefix', 'CN-', 'pad_to', 6,
                      'reset_period', 'yearly', 'next_value', 1),
   120),

  ('sales-lifecycle', 2, 'document_type', 'sales_credit_note',
   jsonb_build_object('code', 'sales_credit_note', 'base_type', 'credit_reference',
     'name', 'Credit note',
     'numbering_rule', 'sales_credit_note', 'state_machine', 'sales_credit_note',
     'stock_movement_type', 'return_from_customer',
     'posting_rule', 'sales_credit_note'),
   130),

  ('procurement-controls', 3, 'state_machine', 'purchase_credit_note',
   jsonb_build_object(
     'code', 'purchase_credit_note', 'object_type', 'document', 'name', 'Supplier credit note',
     'states', jsonb_build_array(
       jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
       jsonb_build_object('code','issued','name','Issued','is_terminal',true,'is_committed',true,'sort_order',20),
       jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
     'transitions', jsonb_build_array(
       jsonb_build_object('code','issue','name','Issue','from','draft','to','issued','required_permission','procurement.order'),
       jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.order'))),
   100),

  ('procurement-controls', 3, 'posting_rule', 'purchase_credit_note',
   jsonb_build_object(
     'code', 'purchase_credit_note', 'name', 'Supplier credit note', 'ledger', 'GL',
     'event_type', 'document.supplier_credit_note.posted',
     'posting_lines', jsonb_build_array(
       jsonb_build_object('account', jsonb_build_object('purpose', 'goods_received_not_invoiced'),
                          'side', 'debit', 'basis', 'stock_cost', 'rate', 1,
                          'description', 'The receipt, unmade'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'inventory'),
                          'side', 'credit', 'basis', 'stock_cost', 'rate', 1,
                          'description', 'The goods, off the shelf at what they cost'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'goods_received_not_invoiced'),
                          'side', 'credit', 'basis', 'document_value', 'rate', 1,
                          'description', 'The bill, unmade'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'tax_control'),
                          'side', 'credit', 'basis', 'document_tax', 'rate', 1,
                          'description', 'Tax the supplier credits back'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'trade_payable'),
                          'side', 'debit', 'balancing', true,
                          'description', 'What we no longer owe'))),
   110),

  ('procurement-controls', 3, 'numbering_rule', 'purchase_credit_note',
   jsonb_build_object('code', 'purchase_credit_note', 'prefix', 'PCN-', 'pad_to', 6,
                      'reset_period', 'yearly', 'next_value', 1),
   120),

  ('procurement-controls', 3, 'document_type', 'purchase_credit_note',
   jsonb_build_object('code', 'purchase_credit_note', 'base_type', 'return_to_supplier',
     'name', 'Supplier credit note',
     'numbering_rule', 'purchase_credit_note', 'state_machine', 'purchase_credit_note',
     'stock_movement_type', 'return_to_supplier',
     'posting_rule', 'purchase_credit_note'),
   130)
on conflict (install_code, to_version, object_kind, object_key) do update
  set payload = excluded.payload, seq = excluded.seq;

-- The demonstration is the organisation the seeded trading month is built on,
-- and it was configured before either credit note existed. It takes them the
-- way it takes any other change: through the upgrade register, as a change set.
do $demo$
declare
  v_src text := pg_get_functiondef('erp.ensure_demo_configuration(uuid,uuid)'::regprocedure);
  v_needle constant text := '  -- Receivables is where cash application''s posting rule lives.';
begin
  if position(v_needle in v_src) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.ensure_demo_configuration is not the deployed body';
  end if;
  if position('customer credit note' in v_src) > 0 then
    return;
  end if;

  execute replace(v_src, v_needle,
       E'  -- Neither side could give money back until 20260917100000. An\n'
    || E'  -- organisation configured before that takes both credit notes the way\n'
    || E'  -- it takes any other change.\n'
    || E'  if exists (select 1 from erp.module_installation i\n'
    || E'              where i.tenant_id = p_tenant_id and i.install_code = ''sales-lifecycle'')\n'
    || E'     and exists (select 1 from erp.plan_module_upgrade(''sales-lifecycle'')) then\n'
    || E'    perform erp.upgrade_module_configuration(''sales-lifecycle'');\n'
    || E'    v_did := v_did || ''"customer credit note"''::jsonb;\n'
    || E'  end if;\n\n'
    || E'  if exists (select 1 from erp.module_installation i\n'
    || E'              where i.tenant_id = p_tenant_id and i.install_code = ''procurement-controls'')\n'
    || E'     and exists (select 1 from erp.plan_module_upgrade(''procurement-controls'')) then\n'
    || E'    perform erp.upgrade_module_configuration(''procurement-controls'');\n'
    || E'    v_did := v_did || ''"supplier credit note"''::jsonb;\n'
    || E'  end if;\n\n' || v_needle);
end
$demo$;

-- ── 9. The words on the screen ───────────────────────────────────────────────

-- Both doors live on the document a person is already looking at: you credit an
-- invoice from the invoice, and you send goods back from the receipt that
-- brought them. There is no new screen because there is no new place to stand.
-- /documents has never carried a help topic: every door rendered on the document
-- screen is registered under the module it belongs to, and these follow that.
-- A customer credit note is a sales act; sending goods back is a procurement one.
select erp_meta.add_help_actions('/sales', array['erp_raise_customer_credit_note']);
select erp_meta.add_help_actions('/procurement', array['erp_raise_supplier_credit_note']);

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('Credit the customer and take the goods back',
     'The dialog raised from a delivery or a sales invoice (20260917100000).'),
    ('Reverses this despatch: the customer owes less, revenue goes back, and the goods return to the shelf at what they cost rather than at what they sold for. A part return is valued at the average of what the whole despatch cost.',
     'Said under that heading, because valuing a part return at the average is the one thing about this that cannot be made exact, and a person is owed that in advance rather than at the audit.'),
    ('Why it came back',
     'The reason code on a customer credit note, which is the only thing that makes the returns report worth reading.'),
    ('A short code you can count later: damaged, wrong item, over-ordered.',
     'Said under the reason code, because a code is only useful if the same words are used twice.'),
    ('What the customer said',
     'The free note beside the reason code on a customer credit note.'),
    ('Optional, and the only thing anybody will remember six months later.',
     'Said under the note on both credit notes, because the code says what kind and the note says what happened.'),
    ('Credit the supplier and send the goods back',
     'The dialog raised from a goods receipt (20260917100000).'),
    ('Reverses this receipt: the goods leave at what they cost, what we owe the supplier falls by what they are crediting, and the purchase order''s history shows the return.',
     'Said under that heading, because the three effects are on three different screens and a person should know all three before pressing it.'),
    ('Why it is going back',
     'The reason code on a supplier credit note.'),
    ('A short code you can count later: damaged, wrong item, over-supplied.',
     'Said under that reason code, because the buying reasons are not the selling ones.'),
    ('What we told the supplier',
     'The free note beside the reason code on a supplier credit note.')
) as v(text, why)
on conflict (key, locale) do nothing;

-- ── 10. The suite ────────────────────────────────────────────────────────────

create or replace function erp_test.credit_note_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 18;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_uom    uuid; v_site uuid; v_sup uuid; v_cust uuid; v_item uuid;
  v_po     uuid; v_pol uuid; v_grn uuid;
  v_so     uuid; v_sol uuid; v_dn uuid; v_inv uuid;
  v_ccn    uuid; v_scn uuid;
  v_qty    numeric; v_qty2 numeric; v_qty3 numeric;
  v_value  bigint; v_cost bigint;
  v_rev text; v_ar text; v_inv_acc text; v_cos text; v_grni text; v_ap text;
  v_dr bigint; v_cr bigint;
  v_msg1 text; v_msg2 text;
  v_ret_docs integer;
  v_order_seen boolean;
begin
  begin
    v_step := 'an organisation with finance, procurement, sales and inventory installed';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzcn-' || v_tag, 'Credit Note Suite',
      'admin@zzcn-' || v_tag || '.test', 'Credit Note Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzcn-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_sales(15);
    perform erp.configure_inventory('average');
    perform erp.configure_procurement_controls();

    v_rev     := erp.tenant_account_code('revenue');
    v_ar      := erp.tenant_account_code('trade_receivable');
    v_inv_acc := erp.tenant_account_code('inventory');
    v_cos     := erp.tenant_account_code('cost_of_sales');
    v_grni    := erp.tenant_account_code('goods_received_not_invoiced');
    v_ap      := erp.tenant_account_code('trade_payable');

    v_step := 'its own unit, site, places, supplier, customer and product';
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZCEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, rb.entity_id, 'ZCSITE', 'Credit note suite site', 'warehouse', 'active')
    returning id into v_site;
    perform erp.create_location(v_site, 'ZC-RECV', 'Goods in', 'receiving');
    perform erp.create_location(v_site, 'ZC-BULK', 'Bulk', 'bulk');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZCSUP', 'Credit Note Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZCCUS', 'Credit Note Suite Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (rb.tenant_id, v_cust, 'customer',
            jsonb_build_object('credit_limit_minor', 100000000), 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZCWID', 'Credit Note Suite Widget', v_uom, 'active')
    returning id into v_item;

    -- ── 1 and 2. The types exist the day the organisation is made ───────────
    v_step := 'the two credit note types';
    v_cases := v_cases + 1;
    case_name := 'a new organisation holds a customer credit note type';
    passed := v_state is null and exists (
      select 1 from erp.document_type dt
       where dt.tenant_id = rb.tenant_id and dt.code = 'sales_credit_note'
         and dt.status = 'active' and dt.base_type_code = 'credit_reference'
         and dt.stock_movement_type = 'return_from_customer'
         and dt.posting_rule_code = 'sales_credit_note');
    detail := 'installed by erp.configure_sales(), on credit_reference, moving return_from_customer';
    return next;

    v_cases := v_cases + 1;
    case_name := 'a new organisation holds a supplier credit note type';
    passed := v_state is null and exists (
      select 1 from erp.document_type dt
       where dt.tenant_id = rb.tenant_id and dt.code = 'purchase_credit_note'
         and dt.status = 'active' and dt.base_type_code = 'return_to_supplier'
         and dt.stock_movement_type = 'return_to_supplier'
         and dt.posting_rule_code = 'purchase_credit_note');
    detail := 'installed by erp.configure_procurement_controls(), on return_to_supplier';
    return next;

    -- ── 3 and 4. Both rules balance, on bases the bridge knows ──────────────
    v_step := 'the two posting rules';
    v_cases := v_cases + 1;
    case_name := 'the customer credit rule balances';
    begin
      perform erp.assert_posting_rule_balances('sales_credit_note',
        (select max(r.version) from erp.posting_rule r
          where r.tenant_id = rb.tenant_id and r.code = 'sales_credit_note'));
      passed := v_state is null;
      detail := 'five lines, one balancing, every basis one the bridge measures';
    exception when others then
      passed := false; detail := left(sqlerrm, 200);
    end;
    return next;

    v_cases := v_cases + 1;
    case_name := 'the supplier credit rule balances';
    begin
      perform erp.assert_posting_rule_balances('purchase_credit_note',
        (select max(r.version) from erp.posting_rule r
          where r.tenant_id = rb.tenant_id and r.code = 'purchase_credit_note'));
      passed := v_state is null;
      detail := 'five lines, one balancing, goods received not invoiced on both measures';
    exception when others then
      passed := false; detail := left(sqlerrm, 200);
    end;
    return next;

    -- ── The month: a hundred in at a tenner, ten out at twenty-five ─────────
    v_step := 'a hundred widgets arrive at ten pounds each';
    v_po := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_pol := erp.add_document_line(v_po, v_item, 100, 1000, 'a hundred widgets');
    perform erp.transition_document(v_po, 'submit', 'credit note suite');
    perform erp_test.approve_document(v_po, 'credit note suite');
    perform erp.transition_document(v_po, 'send', 'credit note suite');
    v_grn := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn, v_pol, 100, null);
    perform erp.transition_document(v_grn, 'post', 'credit note suite');

    v_step := 'ten are sold at twenty-five pounds each, despatched and invoiced';
    v_so := erp.open_document('sales_order', v_cust, rb.entity_id, v_site);
    v_sol := erp.add_document_line(v_so, v_item, 10, 2500, 'ten widgets');
    perform erp.transition_document(v_so, 'submit', 'credit note suite');
    perform erp_test.approve_document(v_so, 'credit note suite');
    v_dn := (erp.create_delivery_from_order(v_so) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn, 'post', 'credit note suite');
    v_inv := erp.invoice_from_delivery(v_dn, true);
    perform erp.transition_document(v_inv, 'issue', 'credit note suite');

    select coalesce(sum(b.quantity), 0) into v_qty
      from erp.stock_balance b
     where b.tenant_id = rb.tenant_id and b.item_id = v_item;

    v_cases := v_cases + 1;
    case_name := 'ten went out and ninety are left';
    passed := v_state is null and v_qty = 90;
    detail := format('the shelf holds %s', v_qty);
    return next;

    -- ── The customer credit note ────────────────────────────────────────────
    v_step := 'the invoice is credited and the goods come back';
    v_ccn := erp.raise_customer_credit_note(v_inv, 'damaged', 'Two cases crushed in transit');
    perform erp.transition_document(v_ccn, 'issue', 'credit note suite');

    select coalesce(sum(b.quantity), 0) into v_qty2
      from erp.stock_balance b
     where b.tenant_id = rb.tenant_id and b.item_id = v_item;

    v_cases := v_cases + 1;
    case_name := 'the credit note puts the ten back on the shelf';
    passed := v_state is null and v_qty2 = 100;
    detail := format('the shelf holds %s', v_qty2);
    return next;

    select coalesce(sum(m.cost_minor), 0) into v_cost
      from erp.stock_movement m
     where m.tenant_id = rb.tenant_id and m.document_id = v_ccn and not m.is_reversal;

    v_cases := v_cases + 1;
    case_name := 'the goods came back at what they cost, not at what they sold for';
    passed := v_state is null and v_cost = 10000;
    detail := format('the return movement cost %s; the despatch cost 10000 and the sale was 25000', v_cost);
    return next;

    select c.value_minor into v_value
      from erp.item_cost c
     where c.tenant_id = rb.tenant_id and c.item_id = v_item
       and c.site_id is not distinct from v_site;

    v_cases := v_cases + 1;
    case_name := 'the valuation is back where it started, not inflated by the margin';
    passed := v_state is null and v_value = 100000;
    detail := format('the value on hand is %s; a hundred at a tenner is 100000', coalesce(v_value, -1));
    return next;

    select coalesce(sum(jl.debit_minor), 0), coalesce(sum(jl.credit_minor), 0)
      into v_dr, v_cr
      from erp.journal_line jl
      join erp.journal j on j.id = jl.journal_id
      join erp.account a on a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_ccn and a.code = v_rev;

    v_cases := v_cases + 1;
    case_name := 'revenue reverses by what was billed';
    passed := v_state is null and v_dr = 25000 and v_cr = 0;
    detail := format('revenue debited %s, credited %s', v_dr, v_cr);
    return next;

    select coalesce(sum(jl.credit_minor - jl.debit_minor), 0) into v_value
      from erp.journal_line jl
      join erp.journal j on j.id = jl.journal_id
      join erp.account a on a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_ccn and a.code = v_ar;

    v_cases := v_cases + 1;
    case_name := 'the customer owes the gross of the credit less';
    passed := v_state is null and v_value = 25000;
    detail := format('the receivable falls by %s, which is the net plus the tax on it', v_value);
    return next;

    select coalesce(sum(case when a.code = v_inv_acc then jl.debit_minor - jl.credit_minor end), 0),
           coalesce(sum(case when a.code = v_cos then jl.credit_minor - jl.debit_minor end), 0)
      into v_dr, v_cr
      from erp.journal_line jl
      join erp.journal j on j.id = jl.journal_id
      join erp.account a on a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_ccn;

    v_cases := v_cases + 1;
    case_name := 'inventory takes the cost back and cost of sales gives it up';
    passed := v_state is null and v_dr = 10000 and v_cr = 10000;
    detail := format('inventory debited %s, cost of sales credited %s, both at the despatch''s own cost', v_dr, v_cr);
    return next;

    v_cases := v_cases + 1;
    case_name := 'the return register names the two documents it has always had room for';
    select count(*) into v_ret_docs
      from erp.customer_return cr
     where cr.tenant_id = rb.tenant_id
       and cr.original_document_id = v_inv
       and cr.return_document_id = v_ccn
       and cr.credit_document_id = v_ccn
       and cr.status = 'credited';
    passed := v_state is null and v_ret_docs = 1;
    detail := 'return_document_id and credit_document_id, written for the first time';
    return next;

    -- ── The supplier credit note ────────────────────────────────────────────
    v_step := 'ten of the hundred go back to the supplier';
    v_scn := erp.raise_supplier_credit_note(
      v_grn, 'wrong_item', 'Ten of the hundred were the wrong grade',
      jsonb_build_array(jsonb_build_object(
        'line_id', (select l.id from erp.document_line l
                     where l.tenant_id = rb.tenant_id and l.document_id = v_grn
                     order by l.line_no limit 1),
        'quantity', 10)));
    perform erp.transition_document(v_scn, 'issue', 'credit note suite');

    select coalesce(sum(b.quantity), 0) into v_qty3
      from erp.stock_balance b
     where b.tenant_id = rb.tenant_id and b.item_id = v_item;

    v_cases := v_cases + 1;
    case_name := 'the supplier credit note takes the ten off the shelf';
    passed := v_state is null and v_qty3 = 90;
    detail := format('the shelf holds %s', v_qty3);
    return next;

    select coalesce(sum(case when a.code = v_ap then jl.debit_minor - jl.credit_minor end), 0),
           coalesce(sum(case when a.code = v_grni then jl.debit_minor - jl.credit_minor end), 0)
      into v_dr, v_cr
      from erp.journal_line jl
      join erp.journal j on j.id = jl.journal_id
      join erp.account a on a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_scn;

    v_cases := v_cases + 1;
    case_name := 'what we owe the supplier falls by a hundred pounds, and the accrual is left flat';
    passed := v_state is null and v_dr = 10000 and v_cr = 0;
    detail := format('payables debited %s; goods received not invoiced net %s', v_dr, v_cr);
    return next;

    select exists (
      select 1 from erp.document_relation r
       where r.tenant_id = rb.tenant_id
         and r.from_document_id = v_scn
         and r.to_document_id = v_po
         and r.relation_kind = 'returns')
      into v_order_seen;

    v_cases := v_cases + 1;
    case_name := 'the purchase order''s history shows the return';
    passed := v_state is null and v_order_seen;
    detail := 'a returns link from the credit note to the order, which erp.document_lineage() walks';
    return next;

    -- ── The refusals ────────────────────────────────────────────────────────
    v_step := 'the two refusals';
    begin
      perform erp.raise_supplier_credit_note(
        v_grn, 'wrong_item', 'and another hundred on top',
        jsonb_build_array(jsonb_build_object(
          'line_id', (select l.id from erp.document_line l
                       where l.tenant_id = rb.tenant_id and l.document_id = v_grn
                       order by l.line_no limit 1),
          'quantity', 95)));
      v_msg1 := 'no refusal';
    exception when others then
      v_msg1 := sqlerrm;
    end;

    v_cases := v_cases + 1;
    case_name := 'returning more than is still here is refused';
    passed := v_state is null and v_msg1 like 'CLOVEERP_CREDIT_EXCEEDS_WHAT_WENT_OUT:%';
    detail := left(v_msg1, 160);
    return next;

    begin
      perform erp.raise_customer_credit_note(v_so, 'damaged', 'against the order itself');
      v_msg2 := 'no refusal';
    exception when others then
      v_msg2 := sqlerrm;
    end;

    v_cases := v_cases + 1;
    case_name := 'a document that moved no goods cannot be credited';
    passed := v_state is null and v_msg2 like 'CLOVEERP_CREDIT_SOURCE_NOT_CREDITABLE:%';
    detail := left(v_msg2, 160);
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzcn-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'zzcn rolled back with its products, its parties and its credit notes');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_CREDIT_NOTE_SUITE_SHRANK: % case(s), expected %', v_cases, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
end;
$suite$;

revoke all on function erp_test.credit_note_suite() from public, anon;

create or replace function erp_test.assert_credit_note_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 18;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _credit_note on commit drop as
    select * from erp_test.credit_note_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _credit_note;
  drop table _credit_note;
  if v_fail > 0 then
    raise exception E'CLOVEERP_CREDIT_NOTE_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_CREDIT_NOTE_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a credit note returns what was sold: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_credit_note_suite() from public, anon;

-- ── 11. The generators, then the checks that read what changed ───────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_authorise_codes_exist();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internals();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_guidance_sound();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_no_dead_configuration();
select erp.assert_inventory_sane();
-- The two columns erp.customer_return has carried unwritten since
-- 20260829280000 are written for the first time here, which puts them in this
-- check's scope for the first time too.
select erp.assert_write_only_columns();

select erp_test.assert_credit_note_suite();
