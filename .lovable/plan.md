# Supplier bills, payment and supplier balances

## What I found (it changes the plan)

Most of the supplier bill already exists in the engine and was never switched on.

`erp.configure_procurement_controls` — the "Procurement controls" item on the
Configuration screen — already installs a purchase invoice: its own lifecycle
(draft → registered → paid, with dispute and cancel), its own numbering
(`PINV-000001`), and a posting rule that debits goods-received-not-invoiced and
credits trade payables. The demonstration organisation has never had it
installed, which is exactly why roughly £830k sits in the accrual, no supplier
balance exists, and a payment run finds nothing to pay.

So this is smaller than planned. What is genuinely missing:

1. Nothing installs procurement controls during onboarding, so no organisation
   gets supplier bills unless somebody knows to press that button.
2. There is no way to raise a bill from a goods receipt — only line-by-line
   against an order line, with the quantity typed by hand.
3. Approving a payment run marks it approved and stops. No bank payment is
   posted, no payable is settled, no bill is marked paid.
4. There is no supplier balances or payables ageing anywhere in the product.

## What you will be able to do

- Receive goods, then raise the supplier's bill straight from the receipt: the
  quantities and prices come from what actually arrived, not from typing.
- See **Supplier balances** on Financials — owed, aged into 0–30/31–60/61–90/90+,
  paid, and anything held back by a match exception.
- Propose a payment run, have somebody else approve it, then **pay** it: the
  bank is credited, the payable settled, the bills marked paid, and the
  supplier balance goes to nil.
- Watch goods-received-not-invoiced drain as bills are registered, instead of
  growing for ever.

## Technical shape

One forward-only migration:

- **Configuration.** Add a `supplier_payment` posting rule (debit trade
  payables, credit bank) to `erp.configure_procurement_controls`, and install
  procurement controls as part of demonstration/onboarding configuration so a
  new organisation has supplier bills from day one.
- **`erp.bill_from_receipt(receipt, their_reference, invoice_date)`** — opens a
  `purchase_invoice` for the receipt's supplier, copies each received line
  through the existing `erp.invoice_against` (so three-way match and GRNI
  progress keep working), sets the due date from the supplier's payment terms,
  and relates the bill to the receipt. Refuses an unposted receipt and refuses
  billing the same receipt twice.
- **`erp.pay_payment_run(proposal)`** — for an approved proposal: posts the
  bank/payable journal per line through the existing posting rule, settles the
  payable subledger items, transitions each fully-settled bill to `paid`,
  marks the proposal `paid`, and raises an event. Refuses a proposal that is
  not approved, refuses to pay twice, and keeps held lines unpaid.
- **Reads:** `erp.supplier_balances()`, `erp.payables_ageing(as_at)`,
  `erp.payment_proposal_lines(proposal)`.
- **Doors:** `erp_bill_from_receipt`, `erp_pay_payment_run`,
  `erp_supplier_balances`, `erp_payables_ageing`, `erp_payment_proposal_lines`
  — invoker-rights wrappers, execute revoked from public/anon, granted to
  authenticated, mutating doors registered in the write-allowance register with
  their gate.
- **Proof:** a new `erp_test.supplier_bill_suite()` walking order → receipt →
  bill → proposal → approval → payment → settled, plus refusals (unposted
  receipt, double bill, unapproved run, double payment, self-approval), and
  reconciliation cases asserting GRNI drains by exactly the billed value,
  payables equal the sum of open bills, and the ageing buckets sum to the
  control account.

## Screens

- **Purchasing** — "Bill a receipt" action, and a Purchase invoices panel.
- **Financials** — Supplier balances panel, Payables ageing panel, payment run
  proposal lines inquiry, and a "Pay an approved run" action beside the
  existing propose/approve pair.

All new wording registered as renameable resource strings in English and German.

## Report-accuracy pass

After the journey runs, reconcile line by line and report the numbers:
trial balance nets to zero; every journal balances; receivables and payables
control accounts equal their subledgers; both ageing reports equal their
control account; GRNI equals received-not-invoiced by line; bank movements
equal cash applied plus payments made; inventory value equals the stock ledger.

## Verification

`bun run typecheck`, `bun run lint`, `bun run test`, `bun run build`, the
migration's own assertion suites, and a browser walk of the whole supplier
journey on the demonstration organisation.
