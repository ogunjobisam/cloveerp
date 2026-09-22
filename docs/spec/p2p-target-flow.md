# Clove ERP — Procure to Pay: target flow

Implementable spec. Held to `docs/spec/flow-doctrine.md` — read that first.

Goal: match the user experience of Sage X3 as a well-configured tenant runs it,
while keeping every removed control available as a parameter.

Status: target state. Not what is built today. Section 1 records the gap.

## 0. Instruction to the implementing agent

- Verify current behaviour against the migration files and the diff, never
  against a commit log or an agent's own summary. Previous reports on this repo
  have twice overstated what landed.
- This is a configuration change, not a rebuild. The document spine, state
  machines, approval chains, numbering rules and tolerance tables already exist
  and are correct. Do not add tables.
- Deliver as a change set through the existing B6 promotion route, the same way
  a customer's own change would arrive, so it is reviewable and reversible.
- Assertions before screens.

## 1. What is wrong today

Read from `supabase/migrations/20260829190000_procurement.sql`,
`erp.configure_procurement()`.

The seeded lifecycle makes the user do work the system should do:

- Double approval. The requisition machine approves at `submitted → approved`.
  The purchase order machine then approves again at `pending_approval →
  approved`, via the `purchase_order_value` chain, unconditionally — including
  when the PO is an exact transformation of an already approved requisition and
  no value has moved. This is the single largest source of extra steps.
- Receipt state is clicked, not derived. The PO machine carries three manual
  transitions — `receive_partial`, `receive_rest`, `receive_all` — that only
  describe what posted goods receipts already prove.
- Closure is clicked. `close` is a manual transition where it should follow from
  full receipt and full invoicing.
- Conversion is clicked twice. The requisition's `order` transition and the
  creation of the PO are separate user actions for one decision.
- Settlement is missing from the cycle. The lifecycle stops at goods receipt.
  Supplier invoice and payment exist elsewhere in the schema but are not part of
  the configured procurement flow, so matching has no defined home.

Counted end to end, the current happy path is roughly 13 user actions to get
from a request to a closed, received purchase order. The Sage equivalent is 5.

## 2. The four documents

- Intent — Requisition (`REQ-`), document type `requisition`
- Commitment — Purchase order (`PO-`), document type `purchase_order`
- Fulfilment — Goods receipt (`GRN-`), document type `goods_receipt`
- Settlement — Supplier invoice (`PINV-`) and its payment allocation

No others. Anything currently proposed as a fifth is a status or a parameter.

## 3. Target happy path

Six user actions, across four roles. This is the declared step budget.

### Action 1 — Requester raises the requisition

- One screen. Header: site, supplier, currency, required date. Lines: product,
  quantity, unit, unit price.
- VAT, line totals and document total are derived. The user never types them.
- Supplier price defaults from the catalogue via the existing
  `a_purchase_line_is_priced_from_the_catalogue` behaviour.
- Primary action: Submit. `draft → submitted`.
- Save-as-draft exists but is not on the happy path.

### Action 2 — Approver approves

- One click, from the approval inbox or from the notification.
- `submitted → approved`. Grant code `procurement.approve`.
- Value bands apply here and only here. Below the auto-approval threshold this
  action does not exist and the requisition is approved on submit.

### Action 3 — Buyer creates the purchase order

- One click from the approved requisition: Create purchase order.
- The PO is created pre-filled by transformation through `erp.link_documents`.
  Every line carries over. Nothing is re-keyed.
- The requisition moves to `ordered` as a side effect of the link, not as a
  separate click.
- The PO is created directly in `approved`. It inherits the requisition's
  approval. It does not pass through `draft` or `pending_approval` unless a
  re-approval trigger fires — see section 5.

### Action 4 — Buyer issues the PO

- One click: Issue. Generates the document through the existing document
  pipeline and writes `erp.document_issue`.
- Either emailed direct to the supplier or downloaded and sent manually,
  governed by a parameter. Both write the same issue row.
- `approved → issued`. After this the PO is off the system until goods arrive.
  No further workflow on the sending itself.

### Action 5 — Receiver posts the goods receipt

- One screen. Select the PO. Lines open pre-filled with outstanding quantities.
- Change nothing and you have received everything. Edit a quantity and you have
  received part.
- Over-delivery is governed by `erp.receipt_tolerance` — `over_pct`,
  `under_pct`, `over_action` — which already exists. Inside tolerance the
  receipt posts with a variance flag. Outside it, exception path E2.
- Primary action: Post. Irreversible by design; corrected by reversal, never by
  edit. Receipts require no approval by default.
- The PO's received state updates itself. The receiver does not touch the PO.

### Action 6 — Accounts payable matches and posts the supplier invoice

- One screen. Select the PO or receipt. Three-way match runs automatically
  across order, receipt and invoice.
- Within price and quantity tolerance: post. Outside: exception path E3.
- Payment allocation follows the normal payment run and is not a step in this
  cycle.

The PO closes itself when fully received and fully invoiced.

## 4. Target state machines

### Requisition

- States: `draft` (initial), `submitted`, `approved`, `ordered` (terminal,
  committed), `cancelled` (terminal).
- Transitions: `submit`, `approve`, `reject`, `cancel`, `cancel_submitted`.
- Removed: `order`. The move to `ordered` is now a derived consequence of a
  purchase order existing in lineage, not a user transition.

### Purchase order

- States: `draft` (initial), `pending_approval`, `approved`, `issued`
  (committed), `partially_received` (committed), `received` (committed),
  `closed` (terminal, committed), `cancelled` (terminal).
- Transitions retained: `submit`, `approve`, `reject`, `issue` (renamed from
  `send`), `cancel`, `cancel_approved`.
- Removed as user transitions, now derived: `receive_partial`, `receive_rest`,
  `receive_all`, `close`.
- `draft` and `pending_approval` remain reachable, but only for a PO raised
  directly without a requisition, or one that tripped a re-approval trigger.

### Goods receipt

- Unchanged. `draft` (initial), `posted` (terminal, committed), `cancelled`
  (terminal). Transitions `post`, `cancel`. This machine is already correct.

### Supplier invoice

- States: `draft` (initial), `matched`, `posted` (committed), `paid`
  (terminal, committed), `cancelled` (terminal).
- Transitions: `match`, `post`, `cancel`. `paid` is derived from payment
  allocation, never clicked.

## 5. Parameters and defaults

Thirteen. Every default produces the flow in section 3. Extend
`erp.configure_procurement()` to author these; do not invent a second settings
mechanism.

- `procurement.requisition_required` — must a PO originate from an approved
  requisition. Default: true above the direct-order threshold, false below.
- `procurement.direct_order_threshold_minor` — value below which a buyer may
  raise a PO without a requisition. Default: 0, meaning always require one.
- `procurement.auto_approve_threshold_minor` — requisition value below which
  approval is automatic on submit. Default: 0, meaning always approve.
- `procurement.approval_bands` — value bands to approver role. Default: single
  band, single approver. Second band retained from the existing
  `purchase_order_value` chain but moved onto the requisition.
- `procurement.reapproval_price_pct` — PO unit price above the approved
  requisition by more than this triggers re-approval. Default: 5.
- `procurement.reapproval_qty_pct` — PO quantity above the approved requisition
  by more than this triggers re-approval. Default: 0.
- `procurement.reapproval_on_party_change` — changing the supplier triggers
  re-approval. Default: true.
- `procurement.receipt_approval_required` — goods receipts need approval.
  Default: false.
- `procurement.over_receipt_pct` — maps to `erp.receipt_tolerance.over_pct`.
  Default: 5.
- `procurement.over_receipt_action` — maps to
  `erp.receipt_tolerance.over_action`. Default: accept.
- `procurement.short_close_pct` — outstanding quantity below this closes the PO
  line automatically. Default: 2.
- `procurement.invoice_match_mode` — two-way or three-way. Default: three-way.
- `procurement.invoice_price_tolerance` — the greater of a percentage or an
  absolute minor amount, within which an invoice posts without human action.
  Default: 2 per cent or 500 minor units.

The existing `procurement.match` and `procurement.receive` grant codes are
permissions and are unaffected.

## 6. Derived status rules

None of these are user transitions. Implement as triggers or as derivation in
the read model, and assert that no public door sets them.

- Requisition is `ordered` when a purchase order exists in its lineage.
- Purchase order is `partially_received` when posted receipt quantity is above
  zero and below ordered quantity net of short-close tolerance.
- Purchase order is `received` when posted receipt quantity meets ordered
  quantity, or the shortfall is within `procurement.short_close_pct`.
- Purchase order is `closed` when it is `received` and matched invoice quantity
  meets received quantity.
- Supplier invoice is `paid` when allocated payment meets invoice value.

## 7. Exception paths

Each gets its own screen and is reached only on occurrence. These do not count
against the step budget.

- E1 Re-approval required. A PO deviates from its requisition beyond the
  re-approval parameters. PO is created in `pending_approval` instead of
  `approved`, and the approver sees the original and the deviation side by side.
- E2 Over-receipt beyond tolerance. Posting is refused. Receiver chooses:
  receive to ordered quantity and reject the balance, quarantine the balance, or
  request a PO amendment.
- E3 Invoice mismatch. Invoice falls outside price or quantity tolerance.
  Routed to an AP exception queue showing order, receipt and invoice side by
  side. Resolution is accept variance, raise a query, or request a credit.
- E4 Short receipt decision. Outstanding quantity remains but the buyer wants
  the PO closed. Explicit close with a reason.
- E5 Cancellation after issue. PO already sent to the supplier. Requires the
  approver's grant and records a reason.

## 8. Acceptance assertions

Extend `erp_test.procurement_suite()`. These are the contract.

- A requisition approved at a given value converts to a purchase order in
  `approved` with no further approval, when nothing material has changed.
- A purchase order created from a requisition carries every line, with no field
  re-entered, and appears in the requisition's lineage.
- Creating the purchase order moves the requisition to `ordered` without a user
  transition.
- A purchase order whose unit price exceeds the approved requisition by more
  than `procurement.reapproval_price_pct` is created in `pending_approval`.
- A purchase order whose supplier differs from the requisition is created in
  `pending_approval` when `reapproval_on_party_change` is true.
- A goods receipt opens with outstanding quantity pre-filled and posts with no
  edit.
- A receipt of 103 per cent of ordered quantity posts with a variance flag when
  `over_receipt_pct` is 5.
- A receipt of 110 per cent is refused and raises E2.
- Posting a receipt moves the purchase order to `partially_received` or
  `received` with no user transition.
- A supplier invoice inside price tolerance posts with no human action.
- A purchase order reaches `closed` with no user transition once fully received
  and fully invoiced.
- No public door exists that writes a state on any of the four document types
  outside the declared transitions.
- The happy path from requisition to closed purchase order calls no more than
  six public doors that require a user decision. This is the step budget
  assertion and it must fail loudly when a step is added.

## 9. Out of scope

- Payment run mechanics and bank reconciliation.
- Supplier onboarding and credit control.
- Requisition sourcing against multiple suppliers.
- Landed cost and duty apportionment.

Each is a candidate for later work and none of them may add a step to section 3.
