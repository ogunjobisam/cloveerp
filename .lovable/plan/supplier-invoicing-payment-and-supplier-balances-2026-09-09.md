# Supplier invoicing, payment and supplier balances

Today the purchase side stops at goods received. The receipt raises the "goods
received not invoiced" accrual, and then nothing: there is no supplier bill, no
supplier balance, and the payment run always finds nothing to pay. This closes
that loop and then proves the finance figures line by line.

## What you will be able to do

1. Raise a supplier bill against a goods receipt — quantities and prices come
   from what was actually received, so the bill is matched, not typed.
2. Post it. That clears the accrual raised by the receipt, puts any price
   difference to purchase price variance, and creates the supplier balance.
3. See a **Supplier balances** panel on Financials: what is owed per supplier,
   aged into current / 30 / 60 / 90+ buckets, what has been paid, and what is
   held.
4. Propose a payment run — it now finds the open bills, holds anything in
   dispute or with an unresolved match exception, and totals the rest.
5. Approve and then **pay** the run: money leaves the bank account, the supplier
   balance settles, and each bill moves to paid.

## Controls kept as they are

- The person who proposes a payment run still cannot approve it.
- A bill that disagrees with the receipt is held, not quietly dropped.
- Paying needs the payment permission; matching the bill needs the purchasing
  match permission. Nothing is enforced in the screen alone — the database
  refuses independently.

## Technical shape

**Migration (one, forward-only, with its own assertions):**

- `erp_ref.document_type` gains `supplier_invoice_reference`
  (`affects_finance`, no stock, party required, create permission
  `procurement.match`).
- Procurement configuration change set gains: `supplier_invoice` state machine
  (draft → received → paid / disputed / cancelled), numbering rule `SINV-`,
  document type `supplier_invoice`, posting rules `supplier_invoice`
  (dr 3200 GRNI at received value, cr 3100 payables at invoice value,
  balancing 6200 purchase price variance) and `supplier_payment`
  (dr 3100, cr 2100).
- `erp.supplier_invoice_from_receipt(p_receipt_id, p_their_reference)` — mirror
  of `invoice_from_delivery`; copies received lines, links `invoices` relations,
  advances `quantity_invoiced` so GRNI drains.
- `erp.execute_payment_run(p_proposal_id)` — approved runs only; posts one
  journal per party, settles `subledger_item.settled_minor`, transitions each
  bill to paid, marks the proposal `paid`.
- Reads: `erp.supplier_balances()`, `erp.payables_ageing(p_as_at)`,
  `erp.payment_proposal_lines(p_proposal_id)`.
- Public wrappers `erp_supplier_invoice_from_receipt`,
  `erp_execute_payment_run`, `erp_supplier_balances`, `erp_payables_ageing`,
  `erp_payment_proposal_lines`, each asserting its own governance in the same
  migration, granted to `authenticated` only.
- `erp_test.assert_procure_to_pay_suite` — receipt → bill → GRNI drained to
  zero → payable created → run proposed, approved, paid → payable settled →
  journals balance. Registered in `erp.ci_check_catalogue()`.
- Existing `erp.assert_subledger_reconciles` extended to prove the payable
  control account equals the sum of its subledger, and that the ageing buckets
  sum to the outstanding total on both sides.

**Screens:**

- `src/routes/procurement/index.tsx` — "Bill against a receipt" action and a
  Supplier invoices document panel.
- `src/routes/finance/index.tsx` (via `src/lib/modules.tsx`) — Supplier
  balances panel (owed / aged / paid / held), payables ageing, payment run
  actions including the new Pay step and a proposal lines inquiry.
- Money shown in major units through the existing currency formatting.

**Report-accuracy pass (run, then reported to you):**

Reconcile, line by line: trial balance nets to zero; receivable control =
customer subledger = aged debt buckets; payable control = supplier subledger =
aged creditor buckets; bank control = cash applied and payments made; stock
control = valued movements; GRNI = received-not-invoiced report; commitments
net off. Any discrepancy is fixed, not annotated.

## Verification

`bun run typecheck`, `bun run lint`, `bun run test`, `bun run build`, plus the
new suite and a browser walk of the supplier journey end to end: purchase
order → goods receipt → supplier bill → payment run → settled balance.
