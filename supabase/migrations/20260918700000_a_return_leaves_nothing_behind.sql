set lock_timeout = '30s';

-- =============================================================================
-- 20260918700000  A return leaves nothing behind
-- -----------------------------------------------------------------------------
-- Goods received not invoiced does not come back to nil in a demonstration
-- month that holds a supplier return, and it is not the bills: 20260918300000
-- fixed those. It is the rule the supplier credit note was given a day earlier.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What was left behind
--
-- 20260918170000 gave the supplier credit note five lines:
--
--   DR goods received not invoiced   stock_cost       the receipt, unmade
--   CR inventory                     stock_cost       the goods, off the shelf
--   CR goods received not invoiced   document_value   the bill, unmade
--   CR tax control                   document_tax
--   DR trade payable                 balancing        what we no longer owe
--
-- and argued that the two accrual lines net to "exactly the figure GRNI already
-- holds on the way in". They net to stock_cost less document_value: what the
-- goods are carried at, less what the return is priced at. That is nil only
-- while the two agree, and under average costing they agree only while the
-- product has been received at ONE price. Receive a hundred at ten pounds and a
-- hundred at twelve, send ten back against the second receipt, and the goods
-- leave at eleven pounds — the average — while the credit is priced at twelve.
-- Ten pounds stays in the accrual account, where erp.grni_report() cannot see
-- it: that report takes the open balance out of the ORDER lines, at
-- (received − invoiced) × the agreed price, and a return is neither a receipt
-- nor a bill. The residue is invisible to the one report that would have shown
-- it, and nothing else ever touches the account for a closed order.
--
-- The ten pounds is real. It is the difference between what the goods cost us
-- and what the supplier is giving back, and it belongs in a profit-and-loss
-- account that says so. Not in an accrual for goods awaiting invoices.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Both cases are handled, and this is how they are told apart
--
-- The question a supplier return has to answer before it can post is whether
-- the goods going back had already been billed.
--
--   * Billed. The supplier's bill already cleared the accrual for them
--     (20260918300000 clears it at the value of the receipts the bill matches).
--     There is nothing left in goods received not invoiced to reverse, and a
--     return that debited it anyway would drive the account negative. What falls
--     is the payable: the supplier's crystallised claim.
--
--   * Not billed. No claim ever crystallised. What exists is the accrual the
--     receipt raised, and the return has to reverse it. Debiting the payable
--     instead would leave the accrual standing for goods that are back on the
--     supplier's lorry — a phantom liability nothing would ever clear.
--
-- They are told apart per ORDER LINE, from the two counters the order line
-- already keeps and the returns already recorded against it:
--
--     still accrued = quantity_fulfilled − quantity_invoiced − already returned
--
-- and a return takes its relief from the accrued pool first, up to what is in
-- it; whatever is left over is relief against the payable. That is not a
-- preference, it is the only split that makes the ledger and erp.grni_report()
-- agree, because it is the same pool the report measures. "Already returned" is
-- what OTHER credit notes have taken — committed ones, so a draft that has
-- posted nothing takes nothing — which is what keeps two returns against one
-- order line from each reversing the same accrual.
--
-- The route from a credit note line to that order line exists and is exact:
-- erp.raise_supplier_credit_note() writes a 'returns' relation from each credit
-- line to the RECEIPT line it sends back, and erp.receive_against() wrote a
-- 'fulfils' relation from that receipt line to the ORDER line, carrying the
-- quantity. Nothing had to be invented, and nothing is guessed at.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- The rule from now on
--
--   DR goods received not invoiced   unbilled_return_value
--   DR trade payable                 billed_return_value
--   CR inventory                     stock_cost
--   CR tax control                   document_tax
--   DR purchase price variance       balancing
--
-- The two new measures split erp.document_value_minor() between them by
-- construction — the second is the first subtracted from it — so what the
-- supplier credits is accounted for exactly once however the split falls, and a
-- return of goods that were all billed debits the payable with precisely what
-- the old rule debited it with. Either can measure nothing, and the zero-line
-- skip 20260910165931 put into the bridge drops the line: a return of billed
-- goods raises no accrual line at all, and a return of unbilled goods touches
-- no payable and writes no subledger item against a supplier who never invoiced.
--
-- The variance is the BALANCING line, and that is the point of the change. What
-- is left when the goods have left the shelf at what they cost and the supplier
-- has been credited with what they are crediting is the difference between
-- those two, and there is no third measurement of it. It is signed by the same
-- machinery every balancing line uses: erp.post_document_finance() takes the
-- remainder as abs(debits − credits) and chooses the side, so returning goods
-- dearer than the average credits the variance and returning goods cheaper
-- debits it, and a return that agrees exactly raises no variance line.
--
-- Stock is not touched. The goods leave at what they cost, valued by
-- erp.issue_cost() and read back through stock_cost, exactly as before: that
-- part of 20260918170000 was right and this does not disturb it.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- And the report learns that goods can go back
--
-- erp.grni_report() has counted receipts and bills since 20260829250000 and has
-- never counted returns, so a hundred received and ten sent back still read as
-- a hundred awaiting an invoice. Left alone, reversing the accrual would make
-- the ledger right and the reconciliation wrong, which is worse than either.
-- The report now takes off what committed credit notes have sent back, so
-- "received" means received and still here. The columns are the ones it always
-- had; a line that has sent back more than is still open drops out of the
-- report, as a fully billed one always did.
--
-- What this does NOT do, said plainly: nothing stops a supplier billing for
-- goods that have already gone back. erp.invoice_against() bills against the
-- order line, and the order line's fulfilled count is what it was. Such a bill
-- clears accrual that is no longer open, and erp.grni_reconciliation() then
-- shows a difference — which is the reconciliation doing its job and naming a
-- dispute, not a number to absorb quietly into a variance account. The
-- demonstration does not build one: the Thursday bill now passes over a receipt
-- with goods on their way back, because a bill for returned goods is a
-- conversation with a supplier and a seeder should not invent one.
--
-- Nor does it invent an agreed price where there is none. A goods receipt with
-- no purchase order behind it reaches no order line, so a return against it
-- measures no accrual and takes all its relief on the payable — the same answer
-- 20260918300000 gives an invoice line matched to no order, and for the same
-- reason: erp.grni_report() has only ever counted order lines, so the accrual
-- such a receipt raises was never in the report and taking it out of the ledger
-- would break the pair. That gap is older than this change and is not widened
-- by it; erp_test.price_variance_suite() already holds a case on it.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- This is a change with a date, and posted journals are not restated
--
-- A posting rule is versioned in place: erp.apply_change_set_item() supersedes
-- the version in force with effective_to = the promotion date and writes a new
-- version from it, and every journal line records the rule version that raised
-- it. Credit notes issued before an organisation takes this change keep the
-- journals they have, explained by the rule that was in force on the day. A
-- demonstration month built before today therefore still carries the residue
-- this change stops creating: the figure is in an accrual account, and it is
-- cleared by a journal somebody writes and can explain, not by a migration
-- moving it behind their back. Rebuilding the month builds it under the new
-- rule, which is what the build does on every run.
--
-- Existing organisations take it through the module upgrade register:
-- procurement-controls goes to version 5, and erp.plan_module_upgrade() compares
-- resolved posting_lines rather than the rule code (20260916090000), so a
-- REVISED rule is planned rather than read as already held. No account is
-- planned beside it: the rule names purchase_price_variance, and version 4
-- (20260918300000) already plans that account for every organisation below it —
-- an organisation at version 4 was given it then, and one below 4 is given it by
-- that row on the way past. A second row for the same purpose would be planned
-- twice for the same company and applied twice.
--
-- Proof: erp_test.supplier_return_suite() (14 cases, wrapper pinned), which
-- receives one product at two prices and sends it back twice unbilled, receives
-- a second at two prices and sends it back after the bill, and asserts
-- erp.grni_reconciliation() comes back to nil after every one of them with the
-- whole gap in the variance account. And erp_test.demo_history_suite(), whose
-- reconciliation case is tightened from "the difference is what the returns left
-- behind" to "the difference is nothing" — the seeded month holds five supplier
-- returns and products received at several prices, which is the case this
-- change exists for.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The two measures a supplier's credit note splits into
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.document_unbilled_return_minor(p_document_id uuid)
returns bigint
language sql
stable
security invoker
set search_path = ''
as $$
  -- The accrual this return reverses: for each order line behind the receipt
  -- lines it sends back, the part of the returned quantity that nobody had
  -- billed, at the agreed price. The same arithmetic erp.grni_report() takes
  -- the open balance out at, which is what makes the ledger and the report meet
  -- at nil rather than near it.
  --
  -- The pool is what the order line has received, less what has been billed,
  -- less what OTHER committed credit notes have already taken out of it. A
  -- draft credit note has posted nothing and takes nothing. A return larger
  -- than the pool takes the pool and no more; the rest is a payable that has
  -- already crystallised, and erp.document_billed_return_minor() has it.
  with returned as (
    select fr.to_line_id as order_line_id, sum(rr.quantity) as quantity_now
      from erp.document_line cl
      join erp.document_relation rr
        on rr.tenant_id = cl.tenant_id
       and rr.from_line_id = cl.id
       and rr.relation_kind = 'returns'
       and rr.to_line_id is not null
      join lateral (
        select f.to_line_id
          from erp.document_relation f
         where f.tenant_id = rr.tenant_id
           and f.from_line_id = rr.to_line_id
           and f.relation_kind = 'fulfils'
           and f.to_line_id is not null
         order by f.created_at, f.to_line_id
         limit 1) fr on true
     where cl.tenant_id = erp.current_tenant_id()
       and cl.document_id = p_document_id
       and not coalesce(cl.is_cancelled, false)
     group by fr.to_line_id
  )
  select coalesce(sum(round(
           least(r.quantity_now,
                 greatest(coalesce(ol.quantity_fulfilled, 0)
                          - coalesce(ol.quantity_invoiced, 0)
                          - coalesce(taken.quantity_before, 0), 0))
           * ol.unit_price_minor)), 0)::bigint
    from returned r
    join erp.document_line ol
      on ol.tenant_id = erp.current_tenant_id() and ol.id = r.order_line_id
    join erp.document od
      on od.tenant_id = ol.tenant_id and od.id = ol.document_id
    join erp.document_type odt
      on odt.tenant_id = od.tenant_id and odt.id = od.document_type_id
    left join lateral (
      select sum(rr2.quantity) as quantity_before
        from erp.document_relation rr2
        join erp.document_relation f2
          on f2.tenant_id = rr2.tenant_id
         and f2.from_line_id = rr2.to_line_id
         and f2.relation_kind = 'fulfils'
         and f2.to_line_id = ol.id
        join erp.document cn
          on cn.tenant_id = rr2.tenant_id and cn.id = rr2.from_document_id
        join erp.object_state os
          on os.tenant_id = cn.tenant_id
         and os.object_type = 'document' and os.object_id = cn.id
        join erp.state st on st.id = os.current_state_id
       where rr2.tenant_id = ol.tenant_id
         and rr2.relation_kind = 'returns'
         and rr2.to_line_id is not null
         and rr2.from_document_id <> p_document_id
         and st.is_committed
         and not coalesce(cn.is_cancelled, false)) taken on true
   where odt.base_type_code = 'purchase_order'
$$;

revoke all on function erp.document_unbilled_return_minor(uuid)
  from public, anon, authenticated;

comment on function erp.document_unbilled_return_minor(uuid) is
  'The accrual a supplier credit note reverses: the part of what it sends back '
  'that nobody had billed, at the price that was agreed. The measure a posting '
  'line names as basis unbilled_return_value, so goods received not invoiced is '
  'debited with what the receipt credited for those goods and with nothing else.';

create or replace function erp.document_billed_return_minor(p_document_id uuid)
returns bigint
language sql
stable
security invoker
set search_path = ''
as $$
  -- The rest of what the supplier is crediting: the part of the return whose
  -- goods had already been billed, so the claim it reduces is the payable and
  -- not the accrual. Taken as the remainder rather than summed again, so the
  -- two measures add to the document value by construction and what the
  -- supplier credits is accounted for exactly once.
  select (erp.document_value_minor(p_document_id)
          - erp.document_unbilled_return_minor(p_document_id))::bigint
$$;

revoke all on function erp.document_billed_return_minor(uuid)
  from public, anon, authenticated;

comment on function erp.document_billed_return_minor(uuid) is
  'What a supplier credit note takes off the payable: what it credits, less the '
  'accrual it reverses. The measure a posting line names as basis '
  'billed_return_value. A return of goods nobody had billed measures nothing '
  'here and raises no line, because no claim had crystallised to reduce.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The bridge learns both measures
-- ═════════════════════════════════════════════════════════════════════════════

-- erp.post_document_finance() has been patched by 20260906060000, 20260906080000,
-- 20260906100000, 20260906131000, 20260906135000, 20260910165931, 20260916090000,
-- 20260917010000 and 20260918300000 since the file that last defines it in full,
-- and the refusal sweep of 20260904980000 rewrote its prefixes in place. It is
-- needled on the deployed text, anchored on the last basis 20260918300000 added,
-- and the patches it already carries are asserted still present afterwards.
do $bridge$
declare
  v_sig    constant text := 'erp.post_document_finance(uuid)';
  v_def    text := pg_get_functiondef(v_sig::regprocedure);
  v_basis  constant text := $n$          when 'price_variance' then erp.document_price_variance_minor(p_document_id)
$n$;
  v_new    text;
begin
  if (length(v_def) - length(replace(v_def, v_basis, ''))) / length(v_basis) <> 1 then
    raise exception 'CLOVEERP_BRIDGE_UNRECOGNISED: the basis of an amount in % does not carry the price variance measure 20260918300000 added exactly once', v_sig;
  end if;

  v_new := replace(v_def, v_basis, v_basis
    || $r$          when 'unbilled_return_value' then erp.document_unbilled_return_minor(p_document_id)
          when 'billed_return_value' then erp.document_billed_return_minor(p_document_id)
$r$);

  -- Every patch the deployed body already had, still there afterwards. A
  -- re-emission from a file would have dropped all of these silently.
  if position('erp.document_unbilled_return_minor(p_document_id)' in v_new) = 0
     or position('erp.document_billed_return_minor(p_document_id)' in v_new) = 0
     or position('erp.document_matched_receipt_minor(p_document_id)' in v_new) = 0
     or position('erp.document_price_variance_minor(p_document_id)' in v_new) = 0
     or position('erp.document_tax_minor(p_document_id)' in v_new) = 0
     or position($p$        v_side := case when v_side = 'debit' then 'credit' else 'debit' end;
$p$ in v_new) = 0
     or position('erp.derive_dimensions(p_document_id, acc.code, v_line,' in v_new) = 0
     or position('erp.posting_line_account_code(v_line, p_document_id, led.id)' in v_new) = 0
     or position($q$d.order_behaviour_code = 'blanket'$q$ in v_new) = 0
     or position('d.stock_owner_party_id is not null' in v_new) = 0
     or position('CLOVEERP_NO_PRICE_TO_POST' in v_new) = 0
     or position($z$    if v_amount = 0 then
      v_no := v_no - 1;$z$ in v_new) = 0 then
    raise exception 'CLOVEERP_BRIDGE_UNRECOGNISED: the patched body of % has lost a patch it carried', v_sig;
  end if;

  execute v_new;
end
$bridge$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A basis the bridge does not know is still a wrong number, quietly
-- ═════════════════════════════════════════════════════════════════════════════

-- 20260916090000 wrote the whitelist because the bridge reads an unrecognised
-- basis as the document value — a plausible wrong number, for ever, with
-- nothing saying so. 20260918300000 added two to it and this adds two more, or
-- promotion would refuse the very rule this migration ships. Needled rather
-- than re-emitted so nothing else in that body is disturbed.
do $whitelist$
declare
  v_sig     constant text := 'erp.assert_posting_rule_balances(text, integer)';
  v_def     text := pg_get_functiondef(v_sig::regprocedure);
  v_list    constant text := $n$     and l.value ->> 'basis' not in ('document_value', 'stock_cost', 'document_tax',
                                      'matched_receipt_value', 'price_variance');$n$;
  v_hint    constant text := $h$      hint = 'A line is measured on the document value, the stock cost, the tax on the document, the receipts a supplier''s bill matches, or the difference between the two.';$h$;
  v_comment constant text := $c$  -- And every basis one the bridge measures. The bridge reads an unrecognised
  -- basis as the document value, so a rule that named one would post a plausible
  -- wrong number for ever without anything saying so. 20260918300000 added the
  -- two a supplier's bill splits into.
$c$;
  v_new     text;
begin
  if (length(v_def) - length(replace(v_def, v_list, ''))) / length(v_list) <> 1 then
    raise exception 'CLOVEERP_WHITELIST_UNRECOGNISED: the basis whitelist in % is not the one 20260918300000 left', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_hint, ''))) / length(v_hint) <> 1 then
    raise exception 'CLOVEERP_WHITELIST_UNRECOGNISED: the whitelist hint in % is not the one 20260918300000 left', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_comment, ''))) / length(v_comment) <> 1 then
    raise exception 'CLOVEERP_WHITELIST_UNRECOGNISED: the whitelist comment in % is not the one 20260918300000 left', v_sig;
  end if;

  v_new := replace(v_def, v_list,
    $r$     and l.value ->> 'basis' not in ('document_value', 'stock_cost', 'document_tax',
                                      'matched_receipt_value', 'price_variance',
                                      'unbilled_return_value', 'billed_return_value');$r$);

  v_new := replace(v_new, v_hint,
    $s$      hint = 'A line is measured on the document value, the stock cost, the tax on the document, the receipts a supplier''s bill matches, the difference between those two, or the accrual and the payable a return to a supplier splits into.';$s$);

  v_new := replace(v_new, v_comment,
    $t$  -- And every basis one the bridge measures. The bridge reads an unrecognised
  -- basis as the document value, so a rule that named one would post a plausible
  -- wrong number for ever without anything saying so. 20260918300000 added the
  -- two a supplier's bill splits into and 20260918700000 the two a return does.
$t$);

  if position('unbilled_return_value' in v_new) = 0
     or position('billed_return_value' in v_new) = 0
     or position('matched_receipt_value' in v_new) = 0
     or position('price_variance' in v_new) = 0
     or position('CLOVEERP_POSTING_RULE_NOT_IN_THIS_ORGANISATION' in v_new) = 0
     or position('erp.posting_rule_raises_nothing(v_lines)' in v_new) = 0
     or position('CLOVEERP_POSTING_RULE_SIDE' in v_new) = 0
     or position('erp.posting_rule_imbalance(v_lines)' in v_new) = 0 then
    raise exception 'CLOVEERP_WHITELIST_UNRECOGNISED: the patched body of % has lost something it carried', v_sig;
  end if;

  execute v_new;
end
$whitelist$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The report learns that goods can go back
-- ═════════════════════════════════════════════════════════════════════════════

-- Guarded before it is replaced, because a body that has moved on since
-- 20260829250000 is one this replacement would silently undo.
do $report$
declare
  v_def  text := pg_get_functiondef('erp.grni_report()'::regprocedure);
  v_open constant text := $n$       and coalesce(ol.quantity_fulfilled, 0) > coalesce(ol.quantity_invoiced, 0)$n$;
begin
  if (length(v_def) - length(replace(v_def, v_open, ''))) / length(v_open) <> 1 then
    raise exception 'CLOVEERP_GRNI_REPORT_UNRECOGNISED: erp.grni_report() does not choose its open lines the way 20260829250000 wrote it; it is no longer the body this migration replaces';
  end if;
  if position('erp.current_tenant_id()' in v_def) = 0
     or position($p$dt.base_type_code = 'purchase_order'$p$ in v_def) = 0
     or position($q$when current_date - received_on <= 30 then '0-30'$q$ in v_def) = 0 then
    raise exception 'CLOVEERP_GRNI_REPORT_UNRECOGNISED: erp.grni_report() no longer reads what this migration expects it to read';
  end if;
end
$report$;

create or replace function erp.grni_report()
returns table (order_line_id uuid, order_number text, party_name text,
               item_code text, received_quantity numeric, invoiced_quantity numeric,
               open_quantity numeric, open_value_minor bigint,
               received_on date, age_days integer, bucket text)
language sql
stable
security invoker
set search_path = ''
as $$
  with lines as (
    select ol.id, d.document_number, p.name as party_name, i.code as item_code,
           coalesce(ol.quantity_fulfilled, 0) as recvd_gross,
           -- What has gone back. Counted from committed credit notes only: the
           -- relations are written when the note is raised and the journal is
           -- raised when it is issued, so a draft that has posted nothing must
           -- take nothing out of the report or the report would run ahead of
           -- the ledger. A customer return reaches a sales order line and is
           -- filtered out with the rest of them by the base type below.
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
           coalesce(ol.quantity_invoiced, 0) as invd,
           ol.unit_price_minor,
           (select min(rd.document_date)
              from erp.document_relation rel
              join erp.document rd on rd.id = rel.from_document_id
              join erp.document_type rdt on rdt.id = rd.document_type_id
             where rel.to_line_id = ol.id and rdt.base_type_code = 'receipt') as received_on
      from erp.document_line ol
      join erp.document d on d.id = ol.document_id
      join erp.document_type dt on dt.id = d.document_type_id
      left join erp.party p on p.id = d.party_id
      left join erp.item i on i.id = ol.item_id
     where ol.tenant_id = erp.current_tenant_id()
       and dt.base_type_code = 'purchase_order'
       and not ol.is_cancelled
       -- The cheap test first, and it loses nothing: a line whose gross receipts
       -- do not exceed what has been billed cannot be open once what went back
       -- is taken off as well.
       and coalesce(ol.quantity_fulfilled, 0) > coalesce(ol.quantity_invoiced, 0)
  )
  select id, document_number, party_name, item_code,
         recvd_gross - returned, invd,
         (recvd_gross - returned) - invd,
         round(((recvd_gross - returned) - invd) * unit_price_minor)::bigint,
         received_on,
         (current_date - received_on)::integer,
         case
           when received_on is null then 'unknown'
           when current_date - received_on <= 30 then '0-30'
           when current_date - received_on <= 60 then '31-60'
           when current_date - received_on <= 90 then '61-90'
           else '90+'
         end
    from lines
   where recvd_gross - returned > invd
   order by received_on nulls last
$$;

comment on function erp.grni_report() is
  'Spec 5.3: goods-received-not-invoiced with ageing. What has arrived, has not '
  'gone back, and has not been billed, oldest first — an old balance is either '
  'an invoice nobody sent or a receipt that never happened, and both are worth '
  'knowing about. Returns to a supplier are taken off what arrived from the day '
  'their credit note is issued (20260918700000), so the report and the accrual '
  'account answer the same question.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The rule an organisation is given from now on
-- ═════════════════════════════════════════════════════════════════════════════

do $installer$
declare
  v_sig constant text := 'erp.configure_procurement_controls(text, numeric, numeric, bigint)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_needle constant text := $n$      -- The receipt and the supplier bill, both unwound. Goods
      -- received not invoiced takes the difference between what the goods
      -- are carried at and what the supplier is crediting, which is the
      -- same place it holds that difference on the way in.
      jsonb_build_object('kind','posting_rule','key','purchase_credit_note','payload',
        jsonb_build_object(
          'code','purchase_credit_note','name','Supplier credit note','ledger','GL',
          'event_type','document.supplier_credit_note.posted',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account', v_grni,'side','debit',
                               'basis','stock_cost','rate',1,
                               'description','The receipt, unmade'),
            jsonb_build_object('account', erp.tenant_account_code('inventory'),'side','credit',
                               'basis','stock_cost','rate',1,
                               'description','The goods, off the shelf at what they cost'),
            jsonb_build_object('account', v_grni,'side','credit',
                               'basis','document_value','rate',1,
                               'description','The bill, unmade'),
            jsonb_build_object('account', erp.tenant_account_code('tax_control'),'side','credit',
                               'basis','document_tax','rate',1,
                               'description','Tax the supplier credits back'),
            jsonb_build_object('account', v_ap,'side','debit',
                               'balancing',true,
                               'description','What we no longer owe')))),$n$;
  v_new text;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_PROCUREMENT_INSTALLER_UNRECOGNISED: the supplier credit note rule in % is not the one 20260918170000 left. It reads: %',
      v_sig, substr(v_def, greatest(position('purchase_credit_note' in v_def), 1), 900);
  end if;

  v_new := replace(v_def, v_needle,
    $r$      -- The receipt and the supplier bill, both unwound — and which of them
      -- it is, is a question the measures answer rather than the rule
      -- (20260918700000). Goods received not invoiced is reversed for the part
      -- of the return nobody had billed, at the price that was agreed; the
      -- payable falls by the rest; the goods leave at what they cost; and what
      -- is left between those two is the variance, which is the balancing line
      -- because there is no third measurement of it.
      jsonb_build_object('kind','posting_rule','key','purchase_credit_note','payload',
        jsonb_build_object(
          'code','purchase_credit_note','name','Supplier credit note','ledger','GL',
          'event_type','document.supplier_credit_note.posted',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account', v_grni,'side','debit',
                               'basis','unbilled_return_value','rate',1,
                               'description','The receipt, unmade: the part nobody had billed'),
            jsonb_build_object('account', v_ap,'side','debit',
                               'basis','billed_return_value','rate',1,
                               'description','What we no longer owe for the part already billed'),
            jsonb_build_object('account', erp.tenant_account_code('inventory'),'side','credit',
                               'basis','stock_cost','rate',1,
                               'description','The goods, off the shelf at what they cost'),
            jsonb_build_object('account', erp.tenant_account_code('tax_control'),'side','credit',
                               'basis','document_tax','rate',1,
                               'description','Tax the supplier credits back'),
            jsonb_build_object('account', erp.tenant_account_code('purchase_price_variance'),'side','debit',
                               'balancing',true,
                               'description','What the goods cost against what the supplier credits')))),$r$);

  if position($p$'basis','unbilled_return_value'$p$ in v_new) = 0
     or position($p$'basis','billed_return_value'$p$ in v_new) = 0
     or position($p$'basis','matched_receipt_value'$p$ in v_new) = 0
     or position($p$'basis','price_variance'$p$ in v_new) = 0
     or position($p$'code','purchase_credit_note','name','Supplier credit note'$p$ in v_new) = 0
     or position($p$'stock_movement_type','return_to_supplier'$p$ in v_new) = 0
     or position($p$erp.tenant_account_code('tax_control')$p$ in v_new) = 0
     or position($p$'basis','stock_cost'$p$ in v_new) = 0 then
    raise exception 'CLOVEERP_PROCUREMENT_INSTALLER_UNRECOGNISED: the patched body of % has lost a line it carried', v_sig;
  end if;

  execute v_new;
end
$installer$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. And the organisations already configured are offered it
-- ═════════════════════════════════════════════════════════════════════════════

update erp_ref.module_installer
   set current_version = 5,
       description = 'The supplier bill, the payment rule and the match tolerances. '
                     'Version 2 (20260916410000) debits the tax a supplier charged to '
                     'the tax control account and makes the payable the gross owed; '
                     'version 3 (20260918170000) adds the supplier credit note; '
                     'version 4 (20260918300000) debits goods received not invoiced '
                     'with what the receipt credited and posts the difference to '
                     'purchase price variance; version 5 (20260918700000) does the '
                     'same for a return, reversing the accrual only for goods nobody '
                     'had billed and taking the rest off the payable, so a return no '
                     'longer leaves a residue nothing clears.'
 where install_code = 'procurement-controls';

-- The rule, in the shape erp.plan_module_upgrade() compares: it resolves
-- {"purpose": …} through erp.tenant_account_code() and compares the resolved
-- posting_lines with the rule the organisation holds, so this has to correspond
-- line for line and key for key with what the installer above writes, or the
-- upgrade would be offered for ever.
--
-- No erp_ref.module_upgrade_account row goes with it. The rule names
-- purchase_price_variance and version 4 already plans that account for every
-- organisation below version 4; an organisation at version 4 was given it then.
-- A second row for the same purpose would be planned and applied twice for the
-- same company on one upgrade.
insert into erp_ref.module_upgrade_item
  (install_code, to_version, object_kind, object_key, payload, seq)
values
  ('procurement-controls', 5, 'posting_rule', 'purchase_credit_note',
   jsonb_build_object(
     'code', 'purchase_credit_note', 'name', 'Supplier credit note', 'ledger', 'GL',
     'event_type', 'document.supplier_credit_note.posted',
     'posting_lines', jsonb_build_array(
       jsonb_build_object('account', jsonb_build_object('purpose', 'goods_received_not_invoiced'),
                          'side', 'debit', 'basis', 'unbilled_return_value', 'rate', 1,
                          'description', 'The receipt, unmade: the part nobody had billed'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'trade_payable'),
                          'side', 'debit', 'basis', 'billed_return_value', 'rate', 1,
                          'description', 'What we no longer owe for the part already billed'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'inventory'),
                          'side', 'credit', 'basis', 'stock_cost', 'rate', 1,
                          'description', 'The goods, off the shelf at what they cost'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'tax_control'),
                          'side', 'credit', 'basis', 'document_tax', 'rate', 1,
                          'description', 'Tax the supplier credits back'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'purchase_price_variance'),
                          'side', 'debit', 'balancing', true,
                          'description', 'What the goods cost against what the supplier credits'))),
   110)
on conflict (install_code, to_version, object_kind, object_key) do update
  set payload = excluded.payload, seq = excluded.seq;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The demonstration does not bill goods it has already sent back
-- ═════════════════════════════════════════════════════════════════════════════

-- The Thursday bill (20260918600000) bills the whole of what a receipt brought
-- in, line by line, at five per cent above the agreed price. The Tuesday return
-- (20260918220000) sends a tenth of a receipt line back. Nothing stopped the two
-- choosing the same receipt, and when they did the bill cleared accrual the
-- return had already reversed and the account went the wrong way by what went
-- back. A supplier who bills for returned goods is a dispute, and a seeder
-- should not invent one: the bill now passes over a receipt with goods on their
-- way back and takes the next one nobody has billed.
do $seeder$
declare
  v_sig constant text := 'erp.seed_demo_history(date, date, numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_needle constant text := $n$                            and coalesce(ol.quantity_invoiced, 0) > 0)
$n$;
  v_new text;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_SEEDER_UNRECOGNISED: the Thursday bill in % does not choose an unbilled receipt the way 20260918600000 wrote it', v_sig;
  end if;

  v_new := replace(v_def, v_needle, v_needle ||
    $r$         and not exists (select 1 from erp.document_line gl2
                           join erp.document_relation rr
                             on rr.tenant_id = gl2.tenant_id and rr.to_line_id = gl2.id
                            and rr.relation_kind = 'returns'
                          where gl2.tenant_id = v_tenant and gl2.document_id = g.id)
$r$);

  -- The patches this body already carries, still there afterwards.
  if position($p$extract(isodow from v_day) = 2$p$ in v_new) = 0            -- 20260918220000
     or position($p$extract(isodow from v_day) = 5$p$ in v_new) = 0         -- 20260918220000
     or position($p$extract(isodow from v_day) = 3$p$ in v_new) = 0         -- 20260918100000
     or position($p$extract(isodow from v_day) = 1$p$ in v_new) = 0         -- 20260918600000
     or position('erp.raise_supplier_credit_note(' in v_new) = 0
     or position('erp.raise_customer_credit_note(' in v_new) = 0
     or position('erp.invoice_against(' in v_new) = 0
     or position('erp.create_receipt_from_order(' in v_new) = 0
     or position('erp.create_delivery_from_order(' in v_new) = 0
     or position($p$and rr.relation_kind = 'returns')$p$ in v_new) = 0 then
    raise exception 'CLOVEERP_SEEDER_UNRECOGNISED: the patched body of % has lost a day it carried', v_sig;
  end if;

  execute v_new;
end
$seeder$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.supplier_return_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 14;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_uom uuid; v_site uuid; v_sup uuid; v_item_a uuid; v_item_b uuid;
  v_po_a1 uuid; v_pol_a1 uuid; v_grn_a1 uuid;
  v_po_a2 uuid; v_pol_a2 uuid; v_grn_a2 uuid;
  v_po_b1 uuid; v_pol_b1 uuid; v_grn_b1 uuid;
  v_po_b2 uuid; v_pol_b2 uuid; v_grn_b2 uuid;
  v_bill uuid; v_scn_a1 uuid; v_scn_a2 uuid; v_scn_b1 uuid;
  v_grni text; v_ppv text; v_inv_acc text; v_ap text; v_tax_acc text;
  v_lines jsonb;
  v_grni_dr bigint; v_ap_dr bigint; v_ppv_dr bigint; v_ppv_cr bigint;
  v_inv_cr bigint; v_n integer; v_unit bigint; v_value bigint;
  v_unit_b bigint;
  g record;
begin
  begin
    v_step := 'an organisation with finance, procurement, sales, inventory and controls';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzret-' || v_tag, 'Supplier Return Suite',
      'admin@zzret-' || v_tag || '.test', 'Supplier Return Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzret-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_sales(15);
    perform erp.configure_inventory('average');
    perform erp.configure_procurement_controls();

    v_grni    := erp.tenant_account_code('goods_received_not_invoiced');
    v_ppv     := erp.tenant_account_code('purchase_price_variance');
    v_inv_acc := erp.tenant_account_code('inventory');
    v_ap      := erp.tenant_account_code('trade_payable');
    v_tax_acc := erp.tenant_account_code('tax_control');

    v_step := 'its own unit, site, places, supplier and two products';
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZREA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, rb.entity_id, 'ZRSITE', 'Supplier return suite site', 'warehouse', 'active')
    returning id into v_site;
    perform erp.create_location(v_site, 'ZR-RECV', 'Goods in', 'receiving');
    perform erp.create_location(v_site, 'ZR-BULK', 'Bulk', 'bulk');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZRSUP', 'Supplier Return Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZRWIDA', 'Supplier Return Suite Widget A', v_uom, 'active')
    returning id into v_item_a;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZRWIDB', 'Supplier Return Suite Widget B', v_uom, 'active')
    returning id into v_item_b;

    -- ── 1. The rule a new organisation is given ─────────────────────────────
    v_step := 'the supplier credit note rule a new organisation holds';
    select r.posting_lines into v_lines
      from erp.posting_rule r
     where r.tenant_id = rb.tenant_id and r.code = 'purchase_credit_note'
       and r.status = 'active'
     order by r.version desc limit 1;

    v_cases := v_cases + 1;
    case_name := 'a supplier credit note reverses the accrual, reduces the payable, takes the goods off the shelf, and carries the difference to a variance';
    passed := v_state is null
          and jsonb_array_length(coalesce(v_lines, '[]'::jsonb)) = 5
          and exists (select 1 from jsonb_array_elements(v_lines) l
                       where l.value ->> 'account' = v_grni
                         and l.value ->> 'side' = 'debit'
                         and l.value ->> 'basis' = 'unbilled_return_value')
          and exists (select 1 from jsonb_array_elements(v_lines) l
                       where l.value ->> 'account' = v_ap
                         and l.value ->> 'side' = 'debit'
                         and l.value ->> 'basis' = 'billed_return_value')
          and exists (select 1 from jsonb_array_elements(v_lines) l
                       where l.value ->> 'account' = v_inv_acc
                         and l.value ->> 'side' = 'credit'
                         and l.value ->> 'basis' = 'stock_cost')
          and exists (select 1 from jsonb_array_elements(v_lines) l
                       where l.value ->> 'account' = v_ppv
                         and coalesce((l.value ->> 'balancing')::boolean, false))
          and (select count(*) from jsonb_array_elements(v_lines) l
                where coalesce((l.value ->> 'balancing')::boolean, false)) = 1;
    detail := format('%s line(s): %s on what nobody billed, %s on what was billed, %s at cost, %s balancing',
                     jsonb_array_length(coalesce(v_lines, '[]'::jsonb)),
                     v_grni, v_ap, v_inv_acc, v_ppv);
    return next;

    -- ── 2. And it balances on measures the bridge knows ─────────────────────
    v_step := 'the rule balances at promotion';
    v_cases := v_cases + 1;
    case_name := 'five lines with one balancing line balance, on measures the bridge knows';
    begin
      perform erp.assert_posting_rule_balances('purchase_credit_note',
        (select max(r.version) from erp.posting_rule r
          where r.tenant_id = rb.tenant_id and r.code = 'purchase_credit_note'));
      passed := v_state is null;
      detail := 'erp.posting_rule_imbalance() takes a balancing line as absorbing whatever is left';
    exception when others then
      passed := false; detail := left(sqlerrm, 200);
    end;
    return next;

    -- ── 3. A product received at two prices ─────────────────────────────────
    -- The case the rule built on 20260918170000 gets wrong: while a product has
    -- been received at one price the stock cost and the credit's value agree
    -- and its two accrual lines cancel. At two they do not.
    v_step := 'a hundred at ten pounds and a hundred at twelve';
    v_po_a1 := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_pol_a1 := erp.add_document_line(v_po_a1, v_item_a, 100, 1000, 'a hundred at ten pounds');
    perform erp.transition_document(v_po_a1, 'submit', 'supplier return suite');
    perform erp_test.approve_document(v_po_a1, 'supplier return suite');
    perform erp.transition_document(v_po_a1, 'send', 'supplier return suite');
    v_grn_a1 := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn_a1, v_pol_a1, 100, null);
    perform erp.transition_document(v_grn_a1, 'post', 'supplier return suite');

    v_po_a2 := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_pol_a2 := erp.add_document_line(v_po_a2, v_item_a, 100, 1200, 'a hundred at twelve pounds');
    perform erp.transition_document(v_po_a2, 'submit', 'supplier return suite');
    perform erp_test.approve_document(v_po_a2, 'supplier return suite');
    perform erp.transition_document(v_po_a2, 'send', 'supplier return suite');
    v_grn_a2 := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn_a2, v_pol_a2, 100, null);
    perform erp.transition_document(v_grn_a2, 'post', 'supplier return suite');

    select c.unit_cost_minor, c.value_minor into v_unit, v_value
      from erp.item_cost c
     where c.tenant_id = rb.tenant_id and c.item_id = v_item_a
       and c.site_id is not distinct from v_site;

    v_cases := v_cases + 1;
    case_name := 'two hundred received at two prices are carried at the average of them';
    passed := v_state is null and v_unit = 1100 and v_value = 220000;
    detail := format('unit cost %s over %s of value — neither receipt''s own price',
                     coalesce(v_unit, -1), coalesce(v_value, -1));
    return next;

    -- ── 4, 5. Ten of the dearer receipt go back, unbilled ───────────────────
    v_step := 'ten of the twelve-pound receipt go back before anybody bills it';
    v_scn_a1 := erp.raise_supplier_credit_note(
      v_grn_a2, 'DAMAGED_ARRIVAL', 'Crushed on the pallet',
      jsonb_build_array(jsonb_build_object(
        'line_id', (select l.id from erp.document_line l
                     where l.tenant_id = rb.tenant_id and l.document_id = v_grn_a2
                     order by l.line_no limit 1),
        'quantity', 10)));
    perform erp.transition_document(v_scn_a1, 'issue', 'supplier return suite');

    select coalesce(sum(jl.debit_minor - jl.credit_minor) filter (where a.code = v_grni), 0),
           coalesce(sum(jl.debit_minor - jl.credit_minor) filter (where a.code = v_ap), 0),
           coalesce(sum(jl.debit_minor) filter (where a.code = v_ppv), 0),
           coalesce(sum(jl.credit_minor) filter (where a.code = v_ppv), 0),
           coalesce(sum(jl.credit_minor) filter (where a.code = v_inv_acc), 0),
           count(*)
      into v_grni_dr, v_ap_dr, v_ppv_dr, v_ppv_cr, v_inv_cr, v_n
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_scn_a1;

    v_cases := v_cases + 1;
    case_name := 'a return of goods nobody had billed reverses the accrual at the price that was agreed, and leaves the payable alone';
    passed := v_state is null and v_grni_dr = 12000 and v_ap_dr = 0;
    detail := format('%s debited to %s, %s to %s — nothing had crystallised on the supplier''s account',
                     v_grni_dr, v_grni, v_ap_dr, v_ap);
    return next;

    v_cases := v_cases + 1;
    case_name := 'and the difference between what the goods cost and what the supplier credits is a variance, not a residue';
    passed := v_state is null and v_inv_cr = 11000 and v_ppv_cr = 1000 and v_ppv_dr = 0 and v_n = 3;
    detail := format('%s off the shelf at cost, %s credited to %s on %s line(s): they cost eleven and are credited at twelve',
                     v_inv_cr, v_ppv_cr, v_ppv, v_n);
    return next;

    -- ── 6. And ten of the cheaper receipt, the other way ────────────────────
    v_step := 'ten of the ten-pound receipt go back as well';
    v_scn_a2 := erp.raise_supplier_credit_note(
      v_grn_a1, 'DAMAGED_ARRIVAL', 'Crushed on the pallet as well',
      jsonb_build_array(jsonb_build_object(
        'line_id', (select l.id from erp.document_line l
                     where l.tenant_id = rb.tenant_id and l.document_id = v_grn_a1
                     order by l.line_no limit 1),
        'quantity', 10)));
    perform erp.transition_document(v_scn_a2, 'issue', 'supplier return suite');

    select coalesce(sum(jl.debit_minor - jl.credit_minor) filter (where a.code = v_grni), 0),
           coalesce(sum(jl.debit_minor) filter (where a.code = v_ppv), 0),
           coalesce(sum(jl.credit_minor) filter (where a.code = v_ppv), 0)
      into v_grni_dr, v_ppv_dr, v_ppv_cr
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_scn_a2;

    v_cases := v_cases + 1;
    case_name := 'a return of goods that cost more than they are credited at debits the variance instead of crediting it';
    passed := v_state is null and v_grni_dr = 10000 and v_ppv_dr = 1000 and v_ppv_cr = 0;
    detail := format('%s debited to %s, %s debited to %s: they cost eleven and are credited at ten',
                     v_grni_dr, v_grni, v_ppv_dr, v_ppv);
    return next;

    -- ── 7. And the account reconciles ───────────────────────────────────────
    select * into g from erp.grni_reconciliation();
    v_cases := v_cases + 1;
    case_name := 'goods received not invoiced comes back to nil after a product received at two prices is sent back';
    passed := v_state is null and g.account_code = v_grni and g.difference_minor = 0
          and g.ledger_minor = 198000;
    detail := format('%s: ledger %s against open receipts %s, difference %s',
                     g.account_code, g.ledger_minor, g.open_receipts_minor, g.difference_minor);
    return next;

    -- ── 8. The other product, billed before any of it goes back ─────────────
    v_step := 'a second product received at twenty and twenty-four pounds, and billed';
    v_po_b1 := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_pol_b1 := erp.add_document_line(v_po_b1, v_item_b, 100, 2000, 'a hundred at twenty pounds');
    perform erp.transition_document(v_po_b1, 'submit', 'supplier return suite');
    perform erp_test.approve_document(v_po_b1, 'supplier return suite');
    perform erp.transition_document(v_po_b1, 'send', 'supplier return suite');
    v_grn_b1 := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn_b1, v_pol_b1, 100, null);
    perform erp.transition_document(v_grn_b1, 'post', 'supplier return suite');

    v_po_b2 := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_pol_b2 := erp.add_document_line(v_po_b2, v_item_b, 100, 2400, 'a hundred at twenty-four pounds');
    perform erp.transition_document(v_po_b2, 'submit', 'supplier return suite');
    perform erp_test.approve_document(v_po_b2, 'supplier return suite');
    perform erp.transition_document(v_po_b2, 'send', 'supplier return suite');
    v_grn_b2 := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn_b2, v_pol_b2, 100, null);
    perform erp.transition_document(v_grn_b2, 'post', 'supplier return suite');

    v_bill := erp.open_document('purchase_invoice', v_sup, rb.entity_id, v_site);
    perform erp.invoice_against(v_bill, v_pol_b1, 100, 2000);
    perform erp.transition_document(v_bill, 'register', 'supplier return suite');

    select coalesce(sum(jl.debit_minor - jl.credit_minor) filter (where a.code = v_grni), 0)
      into v_grni_dr
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_bill;

    v_cases := v_cases + 1;
    case_name := 'the supplier''s bill clears the accrual for the goods it matches, so there is nothing left in it for a return to reverse';
    passed := v_state is null and v_grni_dr = 200000;
    detail := format('%s debited to %s by the bill', v_grni_dr, v_grni);
    return next;

    -- ── 9, 10. And then ten of the billed receipt go back ───────────────────
    v_step := 'ten of the billed receipt go back';
    v_scn_b1 := erp.raise_supplier_credit_note(
      v_grn_b1, 'DAMAGED_ARRIVAL', 'Found damaged after the bill came in',
      jsonb_build_array(jsonb_build_object(
        'line_id', (select l.id from erp.document_line l
                     where l.tenant_id = rb.tenant_id and l.document_id = v_grn_b1
                     order by l.line_no limit 1),
        'quantity', 10)));
    perform erp.transition_document(v_scn_b1, 'issue', 'supplier return suite');

    select coalesce(sum(jl.debit_minor - jl.credit_minor) filter (where a.code = v_grni), 0),
           coalesce(sum(jl.debit_minor - jl.credit_minor) filter (where a.code = v_ap), 0),
           coalesce(sum(jl.debit_minor) filter (where a.code = v_ppv), 0),
           coalesce(sum(jl.credit_minor) filter (where a.code = v_inv_acc), 0),
           count(*)
      into v_grni_dr, v_ap_dr, v_ppv_dr, v_inv_cr, v_n
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_scn_b1;

    v_cases := v_cases + 1;
    case_name := 'a return of goods the supplier had already billed does not touch the accrual at all: what falls is what we owe';
    passed := v_state is null and v_grni_dr = 0 and v_ap_dr = 20000
          and not exists (
            select 1 from erp.journal j
              join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
              join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
             where j.tenant_id = rb.tenant_id and j.document_id = v_scn_b1 and a.code = v_grni);
    detail := format('%s to %s and %s to %s: the bill had already cleared the accrual',
                     v_grni_dr, v_grni, v_ap_dr, v_ap);
    return next;

    v_cases := v_cases + 1;
    case_name := 'and that return carries its difference to the variance too, because the product was received at two prices as well';
    passed := v_state is null and v_inv_cr = 22000 and v_ppv_dr = 2000 and v_n = 3;
    detail := format('%s off the shelf at cost against %s credited, %s debited to %s on %s line(s)',
                     v_inv_cr, 20000, v_ppv_dr, v_ppv, v_n);
    return next;

    -- ── 11, 12. Nil, with both kinds of return in the books ─────────────────
    select * into g from erp.grni_reconciliation();
    v_cases := v_cases + 1;
    case_name := 'and with a return of billed goods and two of unbilled goods in the books, the account is still nil';
    passed := v_state is null and g.difference_minor = 0 and g.ledger_minor = 438000;
    detail := format('ledger %s against open receipts %s, difference %s',
                     g.ledger_minor, g.open_receipts_minor, g.difference_minor);
    return next;

    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0) into v_ppv_dr
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.status = 'posted' and a.code = v_ppv;

    v_cases := v_cases + 1;
    case_name := 'the variance account carries every penny of the difference the three returns made, and the accrual account carries none of it';
    passed := v_state is null and v_ppv_dr = 2000;
    detail := format('%s on %s: a thousand credited, a thousand and two thousand debited',
                     v_ppv_dr, v_ppv);
    return next;

    -- ── 13. And the shelf is not revalued by any of it ──────────────────────
    select c.unit_cost_minor into v_unit from erp.item_cost c
     where c.tenant_id = rb.tenant_id and c.item_id = v_item_a
       and c.site_id is not distinct from v_site;
    select c.unit_cost_minor into v_unit_b from erp.item_cost c
     where c.tenant_id = rb.tenant_id and c.item_id = v_item_b
       and c.site_id is not distinct from v_site;

    v_cases := v_cases + 1;
    case_name := 'no return revalued the shelf: the goods left at what they cost and what is left costs what it did';
    passed := v_state is null and v_unit = 1100 and v_unit_b = 2200;
    detail := format('unit cost %s and %s, the averages they were before anything went back',
                     coalesce(v_unit, -1), coalesce(v_unit_b, -1));
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzret-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'zzret rolled back with its orders, its receipts and its credit notes');
  return next;

  -- The count guard says what stopped the fixture. Without this the wrapper
  -- never sees a row, so the message this suite caught into v_state — and the
  -- step that produced it — never reaches the build log, and every break costs
  -- a run to find.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_SUPPLIER_RETURN_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.supplier_return_suite() from public, anon;

create or replace function erp_test.assert_supplier_return_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 14;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _supplier_return on commit drop as
    select * from erp_test.supplier_return_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _supplier_return;
  drop table _supplier_return;
  if v_fail > 0 then
    raise exception E'CLOVEERP_SUPPLIER_RETURN_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_SUPPLIER_RETURN_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a return leaves nothing behind: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_supplier_return_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. The two suites this disturbs, restated rather than relaxed
-- ═════════════════════════════════════════════════════════════════════════════

-- erp_test.credit_note_suite() receives a hundred at ten pounds, sells ten, and
-- sends ten back to the supplier — and nobody has billed that hundred. Under
-- 20260918170000 the relief landed on the payable and the accrual was expected
-- to be flat. It is the other way round now, and that is the change: no claim
-- had crystallised on the supplier's account, so what the return reverses is
-- the receipt. The figures move and the sentence beside them says why, rather
-- than the case being loosened to survive either answer.
do $creditnote$
declare
  v_sig constant text := 'erp_test.credit_note_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_o1 constant text := $o1$    case_name := 'what we owe the supplier falls by a hundred pounds, and the accrual is left flat';
    passed := v_state is null and v_dr = 10000 and v_cr = 0;
    detail := format('payables debited %s; goods received not invoiced net %s', v_dr, v_cr);
$o1$;
  v_r1 constant text := $q1$    case_name := 'nobody had billed the hundred, so the return reverses the accrual and leaves the payable alone';
    passed := v_state is null and v_dr = 0 and v_cr = 10000;
    detail := format('payables debited %s; goods received not invoiced debited %s, which is the receipt unmade (20260918700000)', v_dr, v_cr);
$q1$;
  v_o2 constant text := $o2$      detail := 'five lines, one balancing, goods received not invoiced on both measures';
$o2$;
  v_r2 constant text := $q2$      detail := 'five lines, one balancing: the accrual, the payable, the stock, the tax, and the variance that takes what is left';
$q2$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_o1, ''))) / length(v_o1);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_CREDIT_NOTE_SUITE_UNRECOGNISED: % reads the supplier credit note''s journal % time(s), not once', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_o2, ''))) / length(v_o2);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_CREDIT_NOTE_SUITE_UNRECOGNISED: % describes the supplier credit note rule % time(s), not once', v_sig, v_hits;
  end if;

  v_def := replace(v_def, v_o1, v_r1);
  v_def := replace(v_def, v_o2, v_r2);
  execute v_def;

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('CLOVEERP_CREDIT_NOTE_SUITE_SHRANK' in v_def) = 0
     or position('the goods came back at what they cost, not at what they sold for' in v_def) = 0
     or position('the return register names the two documents it has always had room for' in v_def) = 0
     or position('c_expected constant integer := 19;' in v_def) = 0 then
    raise exception 'CLOVEERP_CREDIT_NOTE_SUITE_UNRECOGNISED: % dropped something it carried, or did not take its restatement', v_sig;
  end if;
end
$creditnote$;

-- erp_test.demo_history_suite() carries two cases this changes.
--
-- The first (20260918220000) says the month sends goods back to a supplier and
-- what we owe goes down. What goes down is now whichever claim existed: the
-- payable where the bill had come, the accrual where it had not, and the
-- month's Tuesday return usually picks a receipt nobody has billed. So the
-- case asks for the relief rather than for the payable, and says both places
-- it may land.
--
-- The second (20260918600000) is the placeholder for this defect: it asserts
-- that goods received not invoiced is out by EXACTLY what the month's returns
-- left in it, which was the honest thing to assert while returns left
-- something. They leave nothing now, so it asserts nothing left — which is the
-- whole of this change, held against a month with five supplier returns and
-- products received at several prices in it.
do $demo$
declare
  v_sig constant text := 'erp_test.demo_history_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_o1 constant text := $o1$   where j.tenant_id = v_tenant and dt.code = 'purchase_credit_note'
     and a.control_kind = 'payable';
$o1$;
  v_r1 constant text := $q1$   where j.tenant_id = v_tenant and dt.code = 'purchase_credit_note'
     and (a.control_kind = 'payable'
          or a.code = erp.tenant_account_code('goods_received_not_invoiced'));
$q1$;
  v_o2 constant text := $o2$, and what we owe down'::text,$o2$;
  v_r2 constant text := $q2$, and the relief where it belongs: the payable where the supplier had billed, the accrual where nobody had (20260918700000)'::text,$q2$;
  v_o3 constant text := $o3$    format('%s supplier credit note(s), %s unit(s) sent back, %s off the payable',$o3$;
  v_r3 constant text := $q3$    format('%s supplier credit note(s), %s unit(s) sent back, %s off what we owed or had accrued',$q3$;
  v_o4 constant text := $o4$  -- ── 8g. And goods received not invoiced still reconciles ───────────────────
  -- To exactly what the month's returns to suppliers left in it, which is
  -- nothing until a product received at two prices is sent back. See the
  -- header of 20260918600000: that residue is the return's, not the bill's.
$o4$;
  v_r4 constant text := $q4$  -- ── 8g. And goods received not invoiced still reconciles ───────────────────
  -- To nothing at all. 20260918600000 could only assert that the difference was
  -- exactly what the month's returns had left in the account, because the rule
  -- of 20260918170000 left the gap between the average cost and the credit's
  -- price there and erp.grni_report() could not see it. 20260918700000 sends
  -- that gap to purchase price variance, reverses the accrual only for goods
  -- nobody had billed, and teaches the report what went back — so the honest
  -- assertion is nil. The residue the returns write is still read, and reported
  -- beside the difference, because a rule that started leaving one again would
  -- show up here first.
$q4$;
  v_o5 constant text := $o5$    coalesce(g.account_code = v_grni_code and g.difference_minor = v_residue, false),
    format('%s: ledger %s, open receipts %s, difference %s; the month''s returns to suppliers left %s',$o5$;
  v_r5 constant text := $q5$    coalesce(g.account_code = v_grni_code and g.difference_minor = 0, false),
    format('%s: ledger %s, open receipts %s, difference %s; the month''s returns moved %s of it',$q5$;
  v_o6 constant text := $o6$  return query select 'goods received not invoiced reconciles to the receipts still open with the month''s bills in it: they cleared both sides alike, and the only difference is what the returns to suppliers left in the account'::text,$o6$;
  v_r6 constant text := $q6$  return query select 'goods received not invoiced reconciles to the receipts still open with the month''s bills and its returns in it: the bills cleared what the receipts credited, the returns reversed only what nobody had billed, and neither left anything behind'::text,$q6$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_o1, ''))) / length(v_o1);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % reads the payable on a supplier credit note % time(s), not once', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_o2, ''))) / length(v_o2);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % names what the return takes off % time(s), not once', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_o3, ''))) / length(v_o3);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % reports what the return took off % time(s), not once', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_o4, ''))) / length(v_o4);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % explains its reconciliation case % time(s), not once', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_o5, ''))) / length(v_o5);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % asserts its reconciliation % time(s), not once', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_o6, ''))) / length(v_o6);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % names its reconciliation case % time(s), not once', v_sig, v_hits;
  end if;

  v_def := replace(v_def, v_o1, v_r1);
  v_def := replace(v_def, v_o2, v_r2);
  v_def := replace(v_def, v_o3, v_r3);
  v_def := replace(v_def, v_o4, v_r4);
  v_def := replace(v_def, v_o5, v_r5);
  v_def := replace(v_def, v_o6, v_r6);
  execute v_def;

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('erp_test.approve_document(v_po, ''suite'')' in v_def) = 0   -- 20260914062000
     or position('purchase_credit_note' in v_def) = 0                      -- 20260918220000
     or position('perform erp.seed_demo_history(v_slice + 10, v_slice + 14, 1);' in v_def) = 0
     or position('purchase_invoice' in v_def) = 0                          -- 20260918600000
     or position('erp.assert_ageing_equals_control()' in v_def) = 0
     or position('''partially_received'', ''received''' in v_def) = 0
     or position('v_cases <> 19' in v_def) = 0
     or position('g.difference_minor = 0' in v_def) = 0 then
    raise exception
      'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % dropped a patch it already had, or did not take its restatement', v_sig;
  end if;
end
$demo$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 10. The generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_dead_configuration();
select erp.assert_inventory_sane();

select erp_test.assert_supplier_return_suite();
-- The three suites this disturbs, proved here rather than left to the
-- catalogue: a restated figure that is wrong costs a forty-minute build to
-- find. erp_test.credit_note_suite() is the one whose figures move;
-- erp_test.price_variance_suite() holds the bill's half of the same account and
-- the whitelist this migration widened; erp_test.finance_depth_suite() carries
-- its own goods-received-not-invoiced reconciliation.
select erp_test.assert_credit_note_suite();
select erp_test.assert_price_variance_suite();
select erp_test.assert_finance_depth_suite();
-- And the month itself, which is the case this change exists for: five supplier
-- returns, products received at several prices, and a reconciliation that now
-- has to come back to nil.
select erp_test.assert_demo_history_suite();
