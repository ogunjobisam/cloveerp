set lock_timeout = '30s';

-- =============================================================================
-- 20261010080000  A supplier's bill bills what it names
-- -----------------------------------------------------------------------------
-- Definition of Done P2P-06: "Post a supplier invoice against a PO with
-- nothing received. Expect: no stock movement. Either blocked or posted to
-- accruals, never to stock." The v1 gate (7 October) held it open as the one
-- S1: a bill reaches goods received not invoiced and drives it the wrong way.
--
-- Measured on a clone of main before a line of this was written:
--
--   A bill raised against an order with nothing received matches, registers
--   and debits goods received not invoiced with what it bills. No stock moves.
--   The owner decided on 5 October (20261006141000) that such a bill is
--   accepted and checked again as its goods post, and the receipt's credit
--   then clears the debit to nil. So this is the "posted to accruals" answer
--   the Definition of Done allows. What was wrong is that nothing could read
--   it: erp.grni_report() lists what was received and not billed, never what
--   was billed and not received, so erp.grni_reconciliation() reported the
--   whole bill as a difference and the close's check
--   (erp.assert_grni_reconciles, 20260929000000) refused a month that was
--   right.
--
--   A bill whose line names no order at all — the supplier bill step's New
--   followed by Add line — registers too, and debits goods received not
--   invoiced with the line's own net (20260918300000 kept that on purpose,
--   for a freight line on a matched bill, before freight had its own bill).
--   No receipt can ever meet that line, so the debit stays for ever. That is
--   the S1: a wrong figure in a control account that nothing clears.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. Registering a supplier's bill on the purchase_invoice rule is refused
--      while any of its lines bills nothing: no order line, no consignment
--      line and no supplier-owned receipt line behind it
--      (CLOVEERP_BILL_LINE_BILLS_NOTHING). The refusal names the bill and the
--      lines, and says what to do: take the line off, and bill the order's
--      line with Invoice against an order, or raise the bill from the receipt
--      with Bill a receipt. Carriage and landed cost are billed on their own
--      types (carrier_bill, landed_cost_bill), whose rules never touch goods
--      received not invoiced, and are not affected.
--   B. erp.grni_bill_timing_minor(): what the report cannot show of the
--      account, signed, per order line at the order's price. A bill posted
--      ahead of its goods takes off what it invoiced beyond what was received.
--      A bill still in draft, which quantity_invoiced already counts, puts
--      back what the report took off before its journal posted. That second
--      part was found by this migration's own suite: any month with a draft
--      bill against received goods failed the close's check by the draft's
--      value. A bill counts as posted once its journal has posted and is not
--      reversed, so a disputed bill, which posted first, counts in full.
--   C. erp.grni_reconciliation() and erp.assert_grni_reconciles() add it to
--      the open receipts. erp.grni_report() is left as it is, because
--      erp.order_is_settled() and the screens read it as "received, not yet
--      billed", and that is still what it says.
--   D. erp_test.bill_bills_what_it_names_suite proves both, P2P-06 as written.
--
-- ── WHAT STAYS AS IT WAS ─────────────────────────────────────────────────────
--
-- A bill registered before its goods is accepted, as the owner decided. Bill a
-- receipt, invoicing an order line, billing what was used, carriage and landed
-- cost all register as before. No posting rule changes.
--
-- Production: no table is altered and no row is changed. On live no order
-- line is billed beyond what has posted (20261006141000), so the billed-ahead
-- part is nil there today. A draft bill against received goods on live now
-- reconciles where it read as a difference.
--
-- Proof: erp_test.bill_bills_what_it_names_suite.
-- =============================================================================

select erp.register_refusal(
  'CLOVEERP_BILL_LINE_BILLS_NOTHING',
  'Registering a supplier bill with a line that bills no order and no receipt.',
  'A bill clears what was received and not yet billed. A line with no order or receipt behind it would sit in that '
  'account for ever, because no delivery can ever meet it.',
  'Take the line off the bill. Then bill the order''s line with Invoice against an order, or raise the bill from the '
  'receipt with Bill a receipt.');

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The lines of a bill that bill nothing, and the refusal
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.bill_lines_billing_nothing(p_document_id uuid)
returns table (line_no integer, description text)
language sql
stable
set search_path = ''
as $$
  -- A line bills something when a relation carries it to a line it bills: an
  -- order line (erp.invoice_against), a consignment order's line or a
  -- supplier-owned receipt's line (erp.bill_from_consumption, through
  -- erp.invoice_against). What the bill clears is measured on exactly those
  -- relations (erp.document_matched_receipt_minor), so a line without one is
  -- the line that would clear nothing and stay on the account.
  select l.line_no, l.description
    from erp.document_line l
   where l.tenant_id = erp.current_tenant_id()
     and l.document_id = p_document_id
     and not coalesce(l.is_cancelled, false)
     and not exists (
       select 1 from erp.document_relation rel
        where rel.tenant_id = l.tenant_id
          and rel.from_line_id = l.id
          and rel.relation_kind = 'invoices'
          and rel.to_line_id is not null)
   order by l.line_no
$$;

revoke all on function erp.bill_lines_billing_nothing(uuid) from public, anon, authenticated;

comment on function erp.bill_lines_billing_nothing(uuid) is
  'The lines of a supplier bill that bill no order line and no receipt line (20261010080000). Registering a bill on '
  'the purchase_invoice rule is refused while any is left, because goods received not invoiced would carry it for ever.';

create or replace function erp.require_bill_lines_bill_something(p_document_id uuid)
returns void
language plpgsql
stable
set search_path = ''
as $$
declare
  v_lines text;
  v_number text;
begin
  select string_agg(format('line %s (%s)', b.line_no, coalesce(nullif(b.description, ''), 'no description')),
                    ', ' order by b.line_no)
    into v_lines
    from erp.bill_lines_billing_nothing(p_document_id) b;

  if v_lines is null then
    return;
  end if;

  select coalesce(d.document_number, d.id::text) into v_number
    from erp.document d
   where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id;

  raise exception 'CLOVEERP_BILL_LINE_BILLS_NOTHING: % has % that bill no order and no receipt',
    v_number, v_lines
    using errcode = '23514',
          hint = format('Take %s off %s. Then bill the order''s line with Invoice against an order, '
                        'or raise the bill from the receipt with Bill a receipt.', v_lines, v_number);
end;
$$;

revoke all on function erp.require_bill_lines_bill_something(uuid) from public, anon, authenticated;

comment on function erp.require_bill_lines_bill_something(uuid) is
  'Refuses, naming the bill and its lines, while a supplier bill holds a line that bills no order and no receipt '
  '(20261010080000). erp.transition_document() asks it as a bill on the purchase_invoice rule registers.';

-- Asked as the bill registers, before the move is made and before anything
-- posts, beside the other refusals of a move a document's own facts forbid.
do $transition_document$
declare
  v_sig  constant text := 'erp.transition_document(uuid, text, text)';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);
$o$;
  v_new  constant text := $n$  -- A supplier's bill registers only what it bills (20261010080000): a line
  -- with no order or receipt behind it would debit goods received not
  -- invoiced with nothing that can ever clear it. Carriage and landed cost
  -- are billed on their own rules and are not asked.
  if p_transition_code = 'register'
     and dt.base_type_code = 'invoice_reference'
     and dt.posting_rule_code = 'purchase_invoice' then
    perform erp.require_bill_lines_bill_something(p_document_id);
  end if;

  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);
$n$;
  n integer;
begin
  if position('erp.require_bill_lines_bill_something(' in v_def) > 0 then
    raise notice '% already asks a bill what it bills; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % context line found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$transition_document$;

-- ═════════════════════════════════════════════════════════════════════════════
-- B. Where the bill and the ledger part in time
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.grni_bill_timing_minor()
returns bigint
language sql
stable
set search_path = ''
as $$
  -- erp.grni_report() takes a line's open quantity as received, less what
  -- went back, less what is invoiced, and never below nought. Two moments
  -- part that from the ledger, and this is the sum of both, signed, at the
  -- order line's price — the arithmetic the bill's own posting used
  -- (erp.document_matched_receipt_minor):
  --
  --   a bill posted before its goods (owner, 5 October) has debited the
  --   account for what is not yet received: a negative open balance the
  --   report cannot show, because it stops at nought;
  --
  --   a bill still in draft is in quantity_invoiced already, so the report
  --   takes it off, while its journal has not posted and the ledger still
  --   holds the receipt's credit.
  --
  -- So per line the account should hold what was received and not gone back,
  -- less what POSTED bills invoice, never below nought; less what posted bills
  -- invoice beyond what was received at all. A return after the bill relieves
  -- the payable, not this account (20260918700000), which is why the received
  -- side of the second term is gross. A bill counts as posted once its journal
  -- has posted and is not reversed: a draft counts nothing, and a disputed
  -- bill, which posted before it was disputed, counts in full. A consignment
  -- order is billed for what was used and the report already reads it so.
  with l as (
    select ol.unit_price_minor as price,
           coalesce(ol.quantity_fulfilled, 0) as recvd,
           coalesce(ol.quantity_invoiced, 0) as invd,
           coalesce((
             select sum(rr.quantity)
               from erp.document_relation rr
               join erp.document_relation fr
                 on fr.tenant_id = rr.tenant_id
                and fr.from_line_id = rr.to_line_id
                and fr.relation_kind = 'fulfils'
                and fr.to_line_id = ol.id
               join erp.document cn
                 on cn.tenant_id = rr.tenant_id and cn.id = rr.from_document_id
               join erp.object_state os
                 on os.tenant_id = cn.tenant_id
                and os.object_type = 'document' and os.object_id = cn.id
               join erp.state st on st.id = os.current_state_id
              where rr.tenant_id = ol.tenant_id
                and rr.relation_kind = 'returns'
                and rr.to_line_id is not null
                and st.is_committed
                and not coalesce(cn.is_cancelled, false)), 0) as returned,
           coalesce((
             select sum(rel.quantity)
               from erp.document_relation rel
               join erp.document bd on bd.tenant_id = rel.tenant_id and bd.id = rel.from_document_id
              where rel.tenant_id = ol.tenant_id
                and rel.to_line_id = ol.id
                and rel.relation_kind = 'invoices'
                and not coalesce(bd.is_cancelled, false)
                and exists (
                  select 1 from erp.journal j
                   where j.tenant_id = bd.tenant_id
                     and j.document_id = bd.id
                     and j.status = 'posted'
                     and not exists (select 1 from erp.journal r
                                      where r.tenant_id = j.tenant_id
                                        and r.reverses_journal_id = j.id
                                        and r.status = 'posted'))), 0) as posted
      from erp.document_line ol
      join erp.document d on d.tenant_id = ol.tenant_id and d.id = ol.document_id
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where ol.tenant_id = erp.current_tenant_id()
       and d.tenant_id = erp.current_tenant_id()
       and dt.base_type_code = 'purchase_order'
       and coalesce(d.order_behaviour_code, '') <> 'consignment'
       and not coalesce(ol.is_cancelled, false)
       -- The cheap test first: a line nobody has invoiced, in draft or posted,
       -- reads the same in the report and the ledger.
       and coalesce(ol.quantity_invoiced, 0) > 0
  )
  select coalesce(sum(round((
           greatest(recvd - returned - posted, 0)
           - greatest(posted - recvd, 0)
           - greatest(recvd - returned - invd, 0)) * price)), 0)::bigint
    from l
$$;

revoke all on function erp.grni_bill_timing_minor() from public, anon, authenticated;

comment on function erp.grni_bill_timing_minor() is
  'What erp.grni_report() cannot show of goods received not invoiced, signed, at the order''s price '
  '(20261010080000): less what posted bills invoice ahead of their goods (owner, 5 October), plus what draft bills '
  'took off the report before their journals posted. The reconciliation and the close''s check add it to the open '
  'receipts.';

-- ═════════════════════════════════════════════════════════════════════════════
-- C. The reconciliation and the close read it
-- ═════════════════════════════════════════════════════════════════════════════

do $grni_reconciliation$
declare
  v_sig  constant text := 'erp.grni_reconciliation()';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$coalesce((select sum(g.open_value_minor) from erp.grni_report() g), 0)::bigint$o$;
  v_new  constant text := $n$(coalesce((select sum(g.open_value_minor) from erp.grni_report() g), 0)::bigint
             + erp.grni_bill_timing_minor())$n$;
  v_note_old constant text := $o$  -- The ledger balance on that account against the receipts that are actually
  -- open.$o$;
  v_note_new constant text := $n$  -- The ledger balance on that account against the receipts that are actually
  -- open, with what the report cannot show of bills that are ahead of their
  -- goods or still in draft (20261010080000).$n$;
  n integer;
begin
  if position('erp.grni_bill_timing_minor()' in v_def) > 0 then
    raise notice '% already reads when bills post; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 2 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % open receipts read % time(s), expected 2', v_sig, n;
  end if;
  n := (length(v_def) - length(replace(v_def, v_note_old, ''))) / length(v_note_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % note found % time(s)', v_sig, n;
  end if;
  execute replace(replace(v_def, v_old, v_new), v_note_old, v_note_new);
end
$grni_reconciliation$;

do $assert_grni$
declare
  v_sig  constant text := 'erp.assert_grni_reconciles()';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  select coalesce(sum(g.open_value_minor), 0)::bigint into v_open
    from erp.grni_report() g;
$o$;
  v_new  constant text := $n$  select coalesce(sum(g.open_value_minor), 0)::bigint into v_open
    from erp.grni_report() g;

  -- With what the report cannot show (20261010080000): a bill registered
  -- before its goods debits the account until the receipt meets it, and a
  -- draft bill is off the report before its journal has posted.
  v_open := v_open + erp.grni_bill_timing_minor();
$n$;
  n integer;
begin
  if position('erp.grni_bill_timing_minor()' in v_def) > 0 then
    raise notice '% already reads when bills post; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % open receipts read found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$assert_grni$;

-- ═════════════════════════════════════════════════════════════════════════════
-- D. The proof
-- ═════════════════════════════════════════════════════════════════════════════

-- Suites that raised a bill by hand to test something else — amending a
-- draft, a cut-off — now put an order behind its lines before registering
-- it, as a person would with Invoice against an order. The bill posts what it
-- posted before: each line clears at its own quantity and price.
create or replace function erp_test.order_behind_bill_lines(p_bill_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.document%rowtype;
  l        record;
  v_po     uuid;
  v_ol     uuid;
  n        integer := 0;
begin
  select * into b from erp.document where tenant_id = v_tenant and id = p_bill_id;
  for l in
    select dl.id, dl.item_id, dl.quantity, dl.unit_price_minor, dl.description
      from erp.document_line dl
     where dl.tenant_id = v_tenant and dl.document_id = p_bill_id
       and dl.line_no in (select x.line_no from erp.bill_lines_billing_nothing(p_bill_id) x)
     order by dl.line_no
  loop
    if v_po is null then
      v_po := erp.open_document('purchase_order', b.party_id, b.entity_id, b.site_id);
    end if;
    v_ol := erp.add_document_line(v_po, l.item_id, l.quantity, l.unit_price_minor, l.description);
    insert into erp.document_relation (
      tenant_id, from_document_id, to_document_id, relation_kind,
      from_line_id, to_line_id, quantity)
    values (v_tenant, p_bill_id, v_po, 'invoices', l.id, v_ol, l.quantity);
    perform erp.refresh_order_line_progress(v_ol);
    n := n + 1;
  end loop;
  return n;
end;
$$;

revoke all on function erp_test.order_behind_bill_lines(uuid) from public, anon;

comment on function erp_test.order_behind_bill_lines(uuid) is
  'For suites: opens one order from the bill''s supplier holding each line of the bill that bills nothing, at the '
  'line''s own quantity and price, and relates the two, so the bill registers as Invoice against an order would '
  'have made it (20261010080000).';

-- The suites that registered such a bill, each given its order.
do $amendment_cut_off$
declare
  v_sig  constant text := 'erp_test.amendment_cut_off_suite()';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$    perform erp.transition_document(v_pinv, 'register', 'amendment cut-off suite');
$o$;
  v_new  constant text := $n$    -- Billed against an order, as a bill must be to register (20261010080000).
    perform erp_test.order_behind_bill_lines(v_pinv);
    perform erp.transition_document(v_pinv, 'register', 'amendment cut-off suite');
$n$;
  n integer;
begin
  if position('erp_test.order_behind_bill_lines(v_pinv)' in v_def) > 0 then
    raise notice '% already bills against an order; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % register line found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$amendment_cut_off$;

do $supplier_tax$
declare
  v_sig  constant text := 'erp_test.supplier_tax_suite()';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  perform erp.transition_document(v_pinv, 'register', 'supplier tax suite');
$o$;
  v_new  constant text := $n$  -- Billed against an order, as a bill must be to register (20261010080000).
  perform erp_test.order_behind_bill_lines(v_pinv);
  perform erp.transition_document(v_pinv, 'register', 'supplier tax suite');
$n$;
  n integer;
begin
  if position('erp_test.order_behind_bill_lines(v_pinv)' in v_def) > 0 then
    raise notice '% already bills against an order; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % register line found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$supplier_tax$;

-- The price variance suite's fourteenth case was the old behaviour itself: a
-- bill with no order behind it cleared in full to goods received not
-- invoiced. It now proves the refusal. Its fifteenth used that bill's four
-- pounds as the difference to find; it keeps what it was for, that the
-- reconciliation finds the account wherever the chart numbers it.
do $price_variance$
declare
  v_sig  constant text := 'erp_test.price_variance_suite()';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$    -- ── 14. A bill with no order behind it is not a variance ────────────────
    v_step := 'a bill with no order behind it at all';
    v_pinv4 := erp.open_document('purchase_invoice', v_sup, rb.entity_id, v_site);
    perform erp.add_document_line(v_pinv4, v_item, 1, 4000, 'billed with no order behind it');
    perform erp.transition_document(v_pinv4, 'register', 'price variance suite');

    select coalesce(sum(jl.debit_minor) filter (where a.code = v_grni), 0),
           coalesce(sum(jl.debit_minor) filter (where a.code = v_ppv), 0)
             + coalesce(sum(jl.credit_minor) filter (where a.code = v_ppv), 0),
           count(*)
      into v_dr, v_ppv_dr, v_n
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_pinv4;

    v_cases := v_cases + 1;
    case_name := 'a bill with no order behind it clears in full, exactly as it did before';
    passed := v_state is null and v_dr = 4000 and v_ppv_dr = 0 and v_n = 2;
    detail := format('%s line(s): %s to %s and nothing to %s — a missing relation is not a variance',
                     v_n, v_dr, v_grni, v_ppv);
    return next;
$o$;
  v_new1 constant text := $n$    -- ── 14. A bill with no order behind it is refused (20261010080000) ─────
    -- It cleared in full to goods received not invoiced until then, and
    -- nothing could ever meet it there.
    v_step := 'a bill with no order behind it at all';
    v_pinv4 := erp.open_document('purchase_invoice', v_sup, rb.entity_id, v_site);
    perform erp.add_document_line(v_pinv4, v_item, 1, 4000, 'billed with no order behind it');
    begin
      perform erp.transition_document(v_pinv4, 'register', 'price variance suite');
      detail := 'it registered';
    exception when others then
      detail := left(sqlerrm, 200);
    end;

    select count(*) into v_n
      from erp.journal j where j.tenant_id = rb.tenant_id and j.document_id = v_pinv4;

    v_cases := v_cases + 1;
    case_name := 'a bill with no order behind it is refused, rather than left on goods received not invoiced';
    passed := v_state is null and detail like 'CLOVEERP_BILL_LINE_BILLS_NOTHING:%' and v_n = 0;
    detail := format('%s; %s journal(s) for it', detail, v_n);
    return next;
$n$;
  v_old2 constant text := $o$    case_name := 'the reconciliation finds goods received not invoiced wherever the chart numbers it, and says what is out';
    passed := v_state is null and g.account_code = '3200'
          and g.ledger_minor = -4000 and g.difference_minor = -4000;$o$;
  v_new2 constant text := $n$    -- Nothing is out now that the bill with no order is refused
    -- (20261010080000); the row is what this case is for.
    case_name := 'the reconciliation finds goods received not invoiced wherever the chart numbers it';
    passed := v_state is null and g.account_code = '3200'
          and g.ledger_minor = 0 and g.difference_minor = 0;$n$;
  n integer;
begin
  if position('CLOVEERP_BILL_LINE_BILLS_NOTHING' in v_def) > 0 then
    raise notice '% already proves the refusal; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % case 14 found % time(s)', v_sig, n;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % case 15 found % time(s)', v_sig, n;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$price_variance$;

create or replace function erp_test.bill_bills_what_it_names_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 10;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  g        record;
  v_step   text := 'provisioning';
  v_state  text;
  v_uom uuid; v_site uuid; v_sup uuid; v_item uuid;
  v_po uuid; v_pol uuid; v_po2 uuid; v_pol2 uuid;
  v_ahead uuid; v_grn uuid; v_grn2 uuid; v_free uuid;
  v_grni text; v_inv_acc text;
  v_ok boolean; v_msg text; v_hint text;
  v_n bigint; v_dr bigint; v_inv_dr bigint; v_ahead_minor bigint;
  v_close text;
  v_free_no integer;
begin
  begin
    v_step := 'an organisation with finance, procurement, sales, inventory and controls';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzbbw-' || v_tag, 'Bill Bills Suite',
      'admin@zzbbw-' || v_tag || '.test', 'Bill Bills Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzbbw-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_sales(15);
    perform erp.configure_inventory('average');
    perform erp.configure_procurement_controls();

    v_grni    := erp.tenant_account_code('goods_received_not_invoiced');
    v_inv_acc := erp.tenant_account_code('inventory');

    v_step := 'its own unit, site, places, supplier and product';
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZBEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, rb.entity_id, 'ZBSITE', 'Bill bills suite site', 'warehouse', 'active')
    returning id into v_site;
    perform erp.create_location(v_site, 'ZB-RECV', 'Goods in', 'receiving');
    perform erp.create_location(v_site, 'ZB-BULK', 'Bulk', 'bulk');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZBSUP', 'Bill Bills Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZBWID', 'Bill Bills Suite Widget', v_uom, 'active')
    returning id into v_item;

    v_step := 'a hundred widgets ordered at ten pounds and sent, nothing received';
    v_po := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_pol := erp.add_document_line(v_po, v_item, 100, 1000, 'a hundred widgets at ten pounds');
    perform erp.transition_document(v_po, 'submit', 'bill bills suite');
    perform erp_test.approve_document(v_po, 'bill bills suite');
    perform erp.transition_document(v_po, 'send', 'bill bills suite');

    -- ── 1. A draft bill ahead of the goods counts nothing ───────────────────
    v_step := 'the supplier''s bill for all hundred, entered before anything arrives';
    v_ahead := erp.open_document('purchase_invoice', v_sup, rb.entity_id, v_site);
    perform erp.invoice_against(v_ahead, v_pol, 100, null);
    perform erp.state_supplier_tax(v_ahead, 20000, 'S', 'bill bills suite: what the bill says');
    select * into g from erp.grni_reconciliation();

    v_cases := v_cases + 1;
    case_name := 'a bill still in draft against nothing received moves nothing, and the account reconciles';
    passed := v_state is null
          and erp.grni_bill_timing_minor() = 0
          and g.ledger_minor = 0 and g.difference_minor = 0;
    detail := format('timing %s, ledger %s, difference %s',
                     erp.grni_bill_timing_minor(), g.ledger_minor, g.difference_minor);
    return next;

    -- ── 2–5. P2P-06 as written: registered with nothing received ────────────
    v_step := 'the bill registered against the order with nothing received';
    perform erp.transition_document(v_ahead, 'register', 'bill bills suite');

    v_cases := v_cases + 1;
    case_name := 'a bill against an order with nothing received registers, as the owner decided on 5 October';
    passed := v_state is null
          and erp.document_state_code(v_ahead) in ('registered', 'disputed');
    detail := format('%s reads %s',
                     (select d.document_number from erp.document d where d.id = v_ahead),
                     erp.document_state_code(v_ahead));
    return next;

    select count(*) into v_n from erp.stock_movement m where m.tenant_id = rb.tenant_id;
    select coalesce(sum(jl.debit_minor) filter (where a.code = v_grni), 0),
           coalesce(sum(jl.debit_minor) filter (where a.code = v_inv_acc), 0)
      into v_dr, v_inv_dr
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_ahead;

    v_cases := v_cases + 1;
    case_name := 'it moves no stock and posts to the accrual, never to stock';
    passed := v_state is null and v_n = 0 and v_dr = 100000 and v_inv_dr = 0;
    detail := format('%s stock movement(s); %s debited to %s, %s to %s',
                     v_n, v_dr, v_grni, v_inv_dr, v_inv_acc);
    return next;

    select * into g from erp.grni_reconciliation();
    v_ahead_minor := erp.grni_bill_timing_minor();

    v_cases := v_cases + 1;
    case_name := 'the reconciliation counts what was billed ahead, so the account agrees with itself';
    passed := v_state is null
          and v_ahead_minor = -100000
          and g.ledger_minor = -100000
          and g.open_receipts_minor = -100000
          and g.difference_minor = 0;
    detail := format('bills ahead of goods %s; ledger %s, expected %s, difference %s',
                     v_ahead_minor, g.ledger_minor, g.open_receipts_minor, g.difference_minor);
    return next;

    v_step := 'the close''s check over a bill registered before its goods';
    begin
      v_close := erp.assert_grni_reconciles();
      v_ok := true;
    exception when others then
      v_ok := false; v_close := left(sqlerrm, 240);
    end;

    v_cases := v_cases + 1;
    case_name := 'and the close''s check passes it, rather than refusing a month that is right';
    passed := v_state is null and v_ok;
    detail := v_close;
    return next;

    -- ── 6. The goods arrive and meet the bill ───────────────────────────────
    v_step := 'the hundred widgets arrive and post';
    v_grn := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn, v_pol, 100, null);
    perform erp.transition_document(v_grn, 'post', 'bill bills suite');
    select * into g from erp.grni_reconciliation();

    v_cases := v_cases + 1;
    case_name := 'when the goods arrive the receipt clears the bill''s debit, and nothing is ahead';
    passed := v_state is null
          and erp.grni_bill_timing_minor() = 0
          and g.ledger_minor = 0 and g.open_receipts_minor = 0 and g.difference_minor = 0;
    detail := format('timing %s; ledger %s, open %s, difference %s',
                     erp.grni_bill_timing_minor(), g.ledger_minor, g.open_receipts_minor, g.difference_minor);
    return next;

    -- ── 7–9. A line that bills nothing is refused ───────────────────────────
    v_step := 'ten more widgets ordered, received, and billed with a line that names no order';
    v_po2 := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_pol2 := erp.add_document_line(v_po2, v_item, 10, 1000, 'ten widgets at ten pounds');
    perform erp.transition_document(v_po2, 'submit', 'bill bills suite');
    perform erp_test.approve_document(v_po2, 'bill bills suite');
    perform erp.transition_document(v_po2, 'send', 'bill bills suite');
    v_grn2 := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn2, v_pol2, 10, null);
    perform erp.transition_document(v_grn2, 'post', 'bill bills suite');

    v_free := erp.open_document('purchase_invoice', v_sup, rb.entity_id, v_site);
    perform erp.invoice_against(v_free, v_pol2, 10, null);
    perform erp.add_document_line(v_free, v_item, 3, 1000, 'three widgets nobody ordered');
    select l.line_no into v_free_no from erp.document_line l
     where l.tenant_id = rb.tenant_id and l.document_id = v_free
       and l.description = 'three widgets nobody ordered';
    perform erp.state_supplier_tax(v_free, 2600, 'S', 'bill bills suite: what the bill says');

    begin
      perform erp.transition_document(v_free, 'register', 'bill bills suite');
      v_ok := false; v_msg := 'the bill registered with a line that bills nothing'; v_hint := '';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BILL_LINE_BILLS_NOTHING:%';
      v_msg := left(sqlerrm, 240);
      get stacked diagnostics v_hint = pg_exception_hint;
    end;

    v_cases := v_cases + 1;
    case_name := 'a bill with a line that names no order and no receipt is refused as it registers';
    passed := v_state is null and v_ok
          and position((select d.document_number from erp.document d where d.id = v_free) in v_msg) > 0
          and position(format('line %s (three widgets nobody ordered)', v_free_no) in v_msg) > 0
          and (select count(*) from erp.bill_lines_billing_nothing(v_free)) = 1;
    detail := v_msg;
    return next;

    v_cases := v_cases + 1;
    case_name := 'and the refusal says to take the line off and bill the order or the receipt';
    passed := v_state is null
          and position('Invoice against an order' in coalesce(v_hint, '')) > 0
          and position('Bill a receipt' in coalesce(v_hint, '')) > 0;
    detail := format('next action: %s', left(coalesce(v_hint, 'none given'), 200));
    return next;

    select count(*) into v_n
      from erp.journal j where j.tenant_id = rb.tenant_id and j.document_id = v_free;
    select * into g from erp.grni_reconciliation();

    v_cases := v_cases + 1;
    case_name := 'nothing posted: the bill is still a draft, and its draft line does not part the report from the ledger';
    passed := v_state is null
          and v_n = 0
          and erp.document_state_code(v_free) = 'draft'
          and erp.grni_bill_timing_minor() = 10000
          and g.ledger_minor = 10000
          and g.difference_minor = 0;
    detail := format('%s journal(s) for the bill, which reads %s; timing %s, ledger %s, difference %s',
                     v_n, erp.document_state_code(v_free), erp.grni_bill_timing_minor(),
                     g.ledger_minor, g.difference_minor);
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzbbw-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'zzbbw rolled back with its orders, receipts and bills');
  return next;

  -- The count guard prints what the fixture caught. Without it a break inside
  -- the block costs a whole build to name.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_BILL_BILLS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_bill_bills_what_it_names_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 10;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _bill_bills_what_it_names on commit drop as
    select * from erp_test.bill_bills_what_it_names_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _bill_bills_what_it_names;
  drop table _bill_bills_what_it_names;
  if v_fail > 0 then
    raise exception E'CLOVEERP_BILL_BILLS_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_BILL_BILLS_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a supplier bill bills what it names: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.bill_bills_what_it_names_suite() from public, anon;
revoke all on function erp_test.assert_bill_bills_what_it_names_suite() from public, anon;

comment on function erp_test.bill_bills_what_it_names_suite() is
  'Definition of Done P2P-06 (20261010080000): a bill against an order with nothing received registers, moves no '
  'stock, posts to the accrual and reconciles, and the receipt clears it; a bill with a line that bills no order and '
  'no receipt is refused as it registers, in words, and posts nothing.';

comment on function erp_test.assert_bill_bills_what_it_names_suite() is
  'erp_test.bill_bills_what_it_names_suite(), ten cases: P2P-06, a supplier invoice with nothing received.';

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
select erp.assert_personal_data_register_sound();
