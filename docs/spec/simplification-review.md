# Clove ERP — Simplification Plan

Single source of truth for the flow simplification programme. Written to be
executed by Claude Code as a dependency graph of work nodes.

Version 3, 21 Sep 2026. Supersedes v1 and v2. v3 folds in the Monday list of
21 Sep: the open demonstration repair becomes node R0, the credit tile finding
attaches to W3, and the parallelism rules change after five migration version
collisions in two days.

Companions, referenced by nodes and not duplicated here:
- `docs/spec/flow-doctrine.md` — the rules in full
- `docs/spec/p2p-target-flow.md` — the worked target flow for procurement

## 1. How Claude Code should use this document

- Section 6 is the machine-readable graph. Parse it, build the dependency tree,
  and work nodes only when every `needs` entry is done.
- Section 7 holds the full specification for each node. Never action a node from
  its one-line graph entry alone — read its spec.
- One node is not one commit. Section 8 groups nodes into PRs. Open one branch
  per PR group, not per node.
- A node is done when its `proves` assertion exists, runs in CI, and passes.
  Code without its assertion is not done.
- If a node's spec turns out to be wrong against the actual tree, stop and say
  so in the PR description rather than improvising a different change.

## 2. Working rules

These are binding for every node.

- **Verify against the migrations and the diff.** Never trust a commit log, an
  agent summary, or this document's own description of current behaviour without
  checking. Reports on this repo have twice overstated what landed.
- **No new tables.** The document spine already carries every document type. If
  a node seems to need a table, it is specified wrongly — stop and flag it.
- **Lifecycle changes are change sets.** State machines and approval chains are
  guarded by `guard_live_configuration()`. Author changes as a B6 change set and
  promote, the same route a customer's change would take. Never write to those
  tables directly.
- **Numbering rules and document types are not guarded** and are written
  directly.
- **Do not rewrite history.** The repo is Lovable-connected and `AGENTS.md` is
  Lovable-managed. Leave both alone.
- **Branch short-lived, PR into main.** There is no test or production branch.
  Supabase preview branching is being switched off; do not rely on a preview
  project for staging.
- **Run the offline preflight before every push, and read its whole output.**
  The summary prints below a refusal, so the last line alone can report success
  while a rule is failing above it.
- **Never hold two open branches that both add migrations** unless they are
  built together as one replay. Independent timestamps collide on the migration
  register key; each branch is green alone and the deploy refuses the second.
- **Do not add checks that parse screen source text.** They couple every branch
  that edits that text in a way CI cannot see.
- **Assertions before screens.** Every behavioural node ships its assertion in
  the same PR.
- **Never add a step.** If a node's change would increase the count of
  decision-requiring doors on a happy path, it is wrong.

## 3. The doctrine, condensed

Full text in `docs/spec/flow-doctrine.md`. The nine rules, for reference while
working:

1. Four events per cycle: Intent, Commitment, Fulfilment, Settlement. Anything
   else is a status or a parameter.
2. Transformation, not re-entry. Children are born pre-filled from parents.
3. Approve the commitment once. Downstream inherits. Re-approval on tolerance
   breach only.
4. Tolerances replace steps. Inside, pass with a flag. Outside, raise an
   exception.
5. Status is derived, never clicked.
6. Off-system stays off-system. A flag, not a workflow.
7. Parameter budget: 15 per cycle, all defaulted to the clean path.
8. Step budget, asserted in CI.
9. Happy path gets a button. Exceptions get a screen.

## 4. Findings, condensed

The engine is right. The seeded configuration is wrong, and a large amount of
the machinery the doctrine asks for is already built and simply not connected.

Scoreboard — user actions on the clean path, today and target:

- Procure to pay: 13 to 6
- Order to cash: 18 to 7
- Manufacturing: 7 minimum, 13 typical, to 4
- Stock count: 3 per task to 1
- Stock transfer: 5 across two screens to 3 on one
- Supplier invoice to payment: 5, or 8 when anything differs, to 3
- Customer invoice to cash: 6 to 2
- Period close: 16 to 24 per month, to 2

The five defects that repeat in every cycle, and which most nodes exist to fix:

- The clicked close — a terminal transition describing what children prove.
- The describe-step — transitions narrating progress already posted.
- The second approval — the same unchanged numbers approved twice.
- Tolerances that exist and never fire — above all
  `erp.check_reapproval_required()`, which implements exactly the right
  semantics and is called by nothing outside a test.
- Exceptions on the same surface as the happy path.

## 5. Sequencing decisions, settled

Recorded so nodes are not re-argued mid-flight.

- **Outbound segmentation first.** Lead with distribution and e-commerce, hold
  manufacturers back. Manufacturing's gaps then block no revenue. Not a code
  node; do it before the campaign runs.
- **Standard tier reworded, not withdrawn.** Remove the implication of job
  costing and WIP from the pricing page. MRP planning, forecasting,
  traceability, quality and recall are real and stay. Price holds at £1,095.
  Not a code node.
- **MTD VAT: boxes and a digitally-linked export, no HMRC submission.** Bridging
  remains a valid MTD route, so recognition is not needed to sell. Nodes V1 and
  V2 only.
- **Two-administrator rule kept**, with a non-live bootstrap path. Node N1.
- **Procurement reseeds first**, as the pilot for the reseed mechanism, then
  sales. Sales is the bigger prize but the harder cycle; do not learn the
  mechanism there.
- **Manufacturing settlement is three to four weeks, not a fortnight.** Plan
  accordingly.

## 6. The graph

Machine-readable. `needs` lists node ids that must be complete first. `pr` is
the PR group from section 8. `proves` names the assertion that closes the node.

```yaml
nodes:
  - id: R0
    title: Merge the open demonstration catch-up repair
    kind: prerequisite
    needs: []
    pr: PR0
    proves: demonstration screens show real receivables ageing and closed periods

  - id: X4
    title: Draw a control only where the actor can complete it
    kind: screen
    needs: [X3]
    pr: PR5
    proves: e2e spec - document screen offers no action its guard will refuse

  - id: N1
    title: Non-live bootstrap path for change set promotion
    kind: enabler
    needs: [R0]
    pr: PR1
    proves: erp_test.change_set_bootstrap_suite

  - id: X1
    title: Step budget assertion framework
    kind: enabler
    needs: [R0]
    pr: PR1
    proves: erp_test.step_budget_suite

  - id: X2
    title: Reachability assertion - every state reachable, every transition called
    kind: enabler
    needs: [R0]
    pr: PR1
    proves: erp_test.assert_reachable_configuration

  - id: X3
    title: No public door writes a document state outside declared transitions
    kind: enabler
    needs: [R0]
    pr: PR1
    proves: erp_test.assert_no_state_side_doors

  - id: C1
    title: VAT state guard on state_supplier_tax
    kind: correctness
    needs: [R0]
    pr: PR2
    proves: erp_test.supplier_tax_suite

  - id: C2
    title: Remove manual settle and pay transitions
    kind: correctness
    needs: [R0]
    pr: PR2
    proves: erp_test.settlement_is_derived_suite

  - id: C3
    title: Permission transfer transitions, remove unreachable discrepancy states
    kind: correctness
    needs: [R0]
    pr: PR2
    proves: erp_test.transfer_order_suite

  - id: C4
    title: Roll operation scrap to works_order.quantity_scrapped
    kind: correctness
    needs: [R0]
    pr: PR2
    proves: erp_test.production_suite

  - id: C5
    title: Count tolerance - OR not AND, and non-zero STOCKTAKE defaults
    kind: correctness
    needs: [R0]
    pr: PR2
    proves: erp_test.count_tolerance_suite

  - id: C6
    title: Recount path for a rejected count task
    kind: correctness
    needs: [C5]
    pr: PR2
    proves: erp_test.count_tolerance_suite

  - id: C7
    title: Link match_exception to purchase_invoice disputed state
    kind: correctness
    needs: [R0]
    pr: PR2
    proves: erp_test.match_exception_suite

  - id: C8
    title: Standard-cost revaluation - spike then decide
    kind: spike
    needs: [R0]
    pr: PR12
    proves: none - produces a decision note

  - id: W1
    title: Wire check_reapproval_required into every cycle
    kind: wiring
    needs: [R0]
    pr: PR3
    proves: erp_test.reapproval_tolerance_suite

  - id: W2
    title: Use the check_margin result and request margin_exception
    kind: wiring
    needs: [R0]
    pr: PR3
    proves: erp_test.margin_floor_suite

  - id: W3
    title: Read the sales.credit_control policy in credit_position
    kind: wiring
    needs: [R0]
    pr: PR3
    proves: erp_test.credit_control_suite

  - id: W4
    title: Filter book_operation_time by is_milestone
    kind: wiring
    needs: [R0]
    pr: PR3
    proves: erp_test.production_suite

  - id: W5
    title: Widen assert_no_dead_configuration to the full register
    kind: wiring
    needs: [C3, C4, W1, W2, W3, W4, M7]
    pr: PR9
    proves: erp.assert_no_dead_configuration

  - id: P1
    title: Reseed requisition and purchase_order state machines
    kind: reseed
    needs: [N1, X2, X3]
    pr: PR4
    proves: erp_test.procurement_suite

  - id: P2
    title: Derive purchase order received, closed and requisition ordered
    kind: reseed
    needs: [P1]
    pr: PR4
    proves: erp_test.procurement_suite

  - id: P3
    title: Thirteen procurement parameters with clean-path defaults
    kind: reseed
    needs: [P1, W1]
    pr: PR4
    proves: erp_test.procurement_controls_suite

  - id: P4
    title: Bring purchase_invoice into the configured procurement lifecycle
    kind: reseed
    needs: [P1, C7]
    pr: PR4
    proves: erp_test.procurement_suite

  - id: P5
    title: P2P step budget of six
    kind: assertion
    needs: [X1, P2, P3, P4]
    pr: PR4
    proves: erp_test.step_budget_suite

  - id: S1
    title: Quotation to sales order transformation
    kind: build
    needs: [R0]
    pr: PR5
    proves: erp_test.quotation_transform_suite

  - id: S2
    title: Reseed sales_order machine and add partially_despatched
    kind: reseed
    needs: [N1, X2, X3]
    pr: PR6
    proves: erp_test.sales_suite

  - id: S3
    title: Derive sales order picking, despatched, invoiced and closed
    kind: reseed
    needs: [S2]
    pr: PR6
    proves: erp_test.sales_suite

  - id: S4
    title: Collapse the double credit approval
    kind: reseed
    needs: [S2, W1, W3]
    pr: PR6
    proves: erp_test.credit_control_suite

  - id: S5
    title: Threshold the sales_manager step and set approval tolerances
    kind: reseed
    needs: [S2, W1]
    pr: PR6
    proves: erp_test.sales_suite

  - id: S6
    title: One-action invoice issue
    kind: simplify
    needs: [R0]
    pr: PR5
    proves: erp_test.document_issue_suite

  - id: S7
    title: Quotation send, accept, decline and expire become flags
    kind: reseed
    needs: [S1, S2]
    pr: PR6
    proves: erp_test.sales_suite

  - id: S8
    title: Over and under-ship tolerance on delivery
    kind: build
    needs: [S3]
    pr: PR6
    proves: erp_test.despatch_tolerance_suite

  - id: S9
    title: O2C step budget of seven
    kind: assertion
    needs: [X1, S1, S3, S4, S5, S6, S7, S8]
    pr: PR6
    proves: erp_test.step_budget_suite

  - id: M1
    title: Works order state machine as configuration
    kind: build
    needs: [N1, X2, X3]
    pr: PR7
    proves: erp_test.production_suite

  - id: M2
    title: Works order settlement - posting rules, WIP absorption, variances
    kind: build
    needs: [M1]
    pr: PR7
    proves: erp_test.production_settlement_suite

  - id: M3
    title: Yield, scrap and completion tolerances
    kind: build
    needs: [M1, C4]
    pr: PR7
    proves: erp_test.production_tolerance_suite

  - id: M4
    title: Firm and release in one action
    kind: reseed
    needs: [M1]
    pr: PR8
    proves: erp_test.production_suite

  - id: M5
    title: Backflush as the installed default
    kind: reseed
    needs: [M1]
    pr: PR8
    proves: erp_test.production_suite

  - id: M6
    title: Inspection door and production trigger points, sampled batch release
    kind: build
    needs: [M1]
    pr: PR8
    proves: erp_test.quality_suite

  - id: M7
    title: Remove dead production states and event kinds
    kind: cleanup
    needs: [M1, M4]
    pr: PR8
    proves: erp.assert_no_dead_configuration

  - id: M8
    title: Manufacturing step budget of four
    kind: assertion
    needs: [X1, M2, M3, M4, M5, M6]
    pr: PR8
    proves: erp_test.step_budget_suite

  - id: I1
    title: Count as a document type with numbering and lifecycle
    kind: build
    needs: [N1, C5, C6]
    pr: PR10
    proves: erp_test.count_document_suite

  - id: I2
    title: Counter worklist screen
    kind: screen
    needs: [I1, I3]
    pr: PR10
    proves: e2e count worklist spec

  - id: I3
    title: Auto-post counts inside tolerance
    kind: simplify
    needs: [C5, I1]
    pr: PR10
    proves: erp_test.count_tolerance_suite

  - id: I4
    title: Adjustment born from count variance, using reason codes
    kind: build
    needs: [I1]
    pr: PR10
    proves: erp_test.stock_adjustment_suite

  - id: I5
    title: Approval chain and threshold for transfer and adjustment
    kind: reseed
    needs: [C3, W1]
    pr: PR11
    proves: erp_test.transfer_order_suite

  - id: I6
    title: Approve buttons on inventory screens, module page cut to three actions
    kind: screen
    needs: [I5, I7]
    pr: PR11
    proves: e2e inventory happy path spec

  - id: I7
    title: Derive transfer order closed
    kind: reseed
    needs: [C3]
    pr: PR11
    proves: erp_test.transfer_order_suite

  - id: I8
    title: Inventory step budgets - count one per task, transfer three
    kind: assertion
    needs: [X1, I3, I6, I7]
    pr: PR11
    proves: erp_test.step_budget_suite

  - id: F1
    title: Period close runs its checks automatically across all ledgers
    kind: simplify
    needs: [F2]
    pr: PR12
    proves: erp_test.period_close_suite

  - id: F2
    title: Blocking check for grni_reviewed
    kind: correctness
    needs: [R0]
    pr: PR12
    proves: erp_test.period_close_suite

  - id: F3
    title: Payment variance, FX and rounding tolerances
    kind: build
    needs: [R0]
    pr: PR12
    proves: erp_test.cash_tolerance_suite

  - id: F4
    title: part_paid state on both invoice machines
    kind: reseed
    needs: [C2, F3]
    pr: PR12
    proves: erp_test.settlement_is_derived_suite

  - id: F5
    title: Cash receipt and remittance document
    kind: build
    needs: [F3]
    pr: PR13
    proves: erp_test.cash_receipt_suite

  - id: V1
    title: Compute all nine VAT 100 boxes
    kind: build
    needs: [C1]
    pr: PR14
    proves: erp_test.vat_return_suite

  - id: V2
    title: Digitally-linked VAT export
    kind: build
    needs: [V1]
    pr: PR14
    proves: erp_test.vat_return_suite
```

## 7. Node specifications

Read the node's spec before working it. File references were read from the tree
on 21 Sep 2026 — confirm each before changing it.

### Prerequisite

**R0 — Merge the demonstration catch-up repair**
The only open PR from the weekend. The deploy is green but the demonstration is
unchanged: receivables still equal overdue-sixty-plus to the penny and open
periods still read 96 of 96. The repair also found that `erp.journal` and
`erp.journal_line` carry three initially-deferred constraint triggers firing at
commit, so with more than one demonstration the original would have
mis-numbered journals silently. Merge it before any node in this plan opens a
branch, then confirm the seeded months carry credit notes, inter-site transfers
and stock adjustments — the builder gained all three after the demonstration was
built.

### Enablers

**N1 — Non-live bootstrap path for change set promotion**
`erp.submit_change_set` plus `erp.configure_procurement`'s closing comment
require a second administrator to approve and promote. On a single-operator demo
tenant this blocks every reseed node. Add an environment-scoped bootstrap: a
non-live environment permits self-approval; a live environment does not. Keep the
two-person rule intact on live — it is a selling point, not friction.
Proves: a live environment still refuses self-approval; a non-live one allows it.
Scope note: this covers configuration promotion only. The demonstration also
cannot walk a payment run, because `erp.approve_payment_run()` refuses the
proposer and the demonstration has one active person. Do not widen N1 to cover
that. Seed a second active approver in the demonstration instead — the demo
should show separation of duties working, not switched off.

**X1 — Step budget assertion framework**
The screens already show step counts per flow, and five are missing while their
siblings show one: Payment on purchasing, Pick and Cash on sales, Correct and
Hand on on stock — so none cannot be told from not counted. Make the declared
budgets the single source those counts read from.
A reusable assertion that walks a named happy path and counts the public doors
called that require a human decision, failing when the count exceeds the cycle's
declared budget. Budgets are declared in one place so a change to one is visible
in review. Every per-cycle budget node depends on this.

**X2 — Reachability assertion**
Fails when a seeded state has no transition reaching it, or a seeded transition
has no caller anywhere in the tree. This is the assertion that would have caught
nine entries in the dead configuration register.

**X4 — Draw a control only where the actor can complete it**
Amend is drawn on every committed line, so on an issued invoice a person presses
it and is refused by name by the amendment guard. The generic document screen
likewise renders every available transition, which is how unpermissioned
transfer transitions became clickable. Render an action only when its guard would
accept it for this actor on this document now. Already queued as a task; this
node supersedes it.

**X3 — No state side doors**
Fails when any function in `public` writes a document state other than through
`erp.transition_document`. This is what stops derived statuses being clicked back
into existence later.

### Correctness

**C1 — VAT state guard**
`erp.state_supplier_tax()` (`20260916410000_a_supplier_states_its_tax.sql:65-100`)
has no state guard. On the `bill_from_receipt` route the bill is registered and
the journal posted before tax is stated, so input VAT never reaches `tax_control`
while `erp.tax_report()` still reports it. Either guard the function to refuse
after posting and make tax part of registration, or reorder `bill_from_receipt`
to state tax first. Prefer the reorder — it keeps the one-button route.
Proves: on the one-button route with VAT, `tax_control` and `tax_report` agree.

**C2 — Remove manual settle and pay**
`settle` on `sales_invoice` (`20260829220000_finance_posting.sql:1577`) and `pay`
on `purchase_invoice` (`20260910094351_...fa.sql:119`) survived the change that
made settlement derived via `erp.settle_paid_document()`. They are still offered
by `erp_available_transitions()`, so Paid can be clicked on a document that owes
money. Remove both from the machines; `settle_paid_document` fires them
internally.
Proves: no path sets paid on a document with a remaining balance.

**C3 — Permission transfer transitions**
`transfer_order` (`20260917130000_stock_moves_between_sites.sql:1192-1218`) has
16 transitions for 8 states. Five enter a `discrepancy` state no function calls;
`discrepancy_to_received` exits it; most carry no `required_permission`, so
`issued` and `in_transit` can be clicked from the generic document screen with no
stock having moved. Remove the discrepancy state and its six transitions, remove
the unreachable cancellations, and give every remaining transition a permission.
Proves: no transfer transition lacks a permission; state cannot advance without a
movement.

**C4 — Roll operation scrap to the works order**
`erp.works_order.quantity_scrapped` is never written; only
`works_order_operation.quantity_scrapped` is (`20260829270000_production.sql:709`).
The batch record (`:1073`) and the works order report both display it and both
read zero. Roll the operation figure to the header on booking.

**C5 — Count tolerance logic**
`20260829240000_inventory_operations.sql:1191-1194` ANDs the absolute and
percentage tolerances, so the absolute always dominates and the percentage can
never widen anything. With `CYCLE_A` at absolute 1 and percent 1, five units on
ten thousand goes to approval. `STOCKTAKE` ships 0 and 0, so every annual count
line goes to approval. Change to OR — inside either tolerance passes — and give
`STOCKTAKE` non-zero defaults.
Proves: five units on ten thousand passes under `CYCLE_A`.

**C6 — Recount path**
`erp.record_count()` refuses anything not `open` (`:1172`) and nothing ever
returns a task to `open`, so a rejected count task is unrecoverable. Add a
recount transition from `rejected` back to `open`, permissioned.

**C7 — Match exception blocks registration**
An out-of-tolerance bill registers and posts anyway while the `match_exception`
sits beside it. Link the exception to `purchase_invoice`'s `disputed` state so
the bill lands disputed and clears through `accept_match_exception()`.

**C8 — Standard-cost revaluation spike**
`20260906090000_a_second_organisation.sql:426` refuses with
`CLOVEERP_STANDARD_REVALUATION_NOT_BUILT`, so a tenant on standard costing can
never change a standard once stock exists. Spike only: size the work, decide
build or document-as-limitation, write the note. Do not build under this node.

### Wiring

**W1 — Wire the re-approval tolerance**
`erp.check_reapproval_required()` (`0014_b4_approval_engine.sql:325`) implements
the doctrine's tolerance semantics and is called by nothing outside a test.
Wire it into procurement, sales and inventory so re-approval fires on breach and
not on routine progression. This is the highest-value node in the document.
Proves, per cycle: an unchanged child inherits its parent's approval and requests
no second one; a child breaching tolerance requests one.

**W2 — Use the margin result**
`erp.check_margin()` is called at `20260829280000_sales_depth.sql:239`, assigned
into `m`, and never read. Use it: below the floor, request the
`margin_exception` chain. The chain and `p_min_margin_pct` already exist.

**W3 — Read the credit control policy**
Pull this forward — it fixes the one high-severity finding on the Monday list.
The sales screen reads "12 blocking trading" and nothing blocks anything: the
demonstration has no party terms rows, so `erp.credit_position()` reports every
customer as not on hold, and `erp.create_document()` only refuses on that
position. Same root cause as below. Fix the policy read, seed party terms in the
demonstration, and until both land, the tile must not claim an enforcement the
doors do not perform.
`20260903160000_base_pack_operations.sql:181-193` defines `check_at_capture`,
`block_at_limit`, `tolerance_pct` and `overdue_days_block`; nothing reads them
and `erp.credit_position()` hardcodes its own test. Read the policy.

**W4 — Milestone time booking**
`book_operation_time()` (`20260829270000_production.sql:682`) is one call per
routing operation with no milestone filter, despite
`works_order_operation.is_milestone` being populated at `:378`. Require booking
only at milestones.

**W5 — Widen the dead configuration assertion**
Extend `erp.assert_no_dead_configuration()` to cover the register: unreachable
accounts, unused reason codes, ungranted-but-required permissions, seeded states
with no caller. Runs last in its PR group because it fails until the cleanups
land.

### Procurement

Target flow, parameters and assertions in full: `docs/spec/p2p-target-flow.md`.
One correction to that document — it states settlement is missing from the cycle.
It is not: `purchase_invoice` exists with its own machine and three-way matching
is automatic and tolerance-driven via `erp.match_three_way()`
(`20260829250000_procurement_depth.sql:528, 1156`). What was missing is that the
procurement lifecycle configuration did not include it. Node P4 fixed that in
PR4 (20260922390000): one press of Procurement installs the supplier bill and
credit note lifecycles with it, and `p2p-target-flow.md` is corrected.

**P1** Reseed both machines. Corrected in PR4 (20260922380000): no move is
removed and no code is renamed, because a document runs on the version it
started on. The requisition's `order` and the purchase order's
`receive_partial` become automatic, the moves P2 derives are refused pressed
over nothing, and `send` reads "Issue to supplier". A PO converted from an
approved requisition, unchanged and to the supplier and site it named, is born
`approved` by the new move `inherit_approval`.
**P2** Derive requisition `ordered` from lineage; PO `partially_received`,
`received` and `closed` from posted receipts and matched invoices.
**P3** The thirteen parameters, authored through `configure_procurement`, all
defaulted to the clean path. Do not add a second settings mechanism. Corrected
in PR4 (20260923100000): nine are delivered and four deferred. The three new
keys live in one configuration type, `procurement.policy`, which version 3 of
the procurement lifecycle writes; the other six were already the approval
chains, `approval.reapproval_tolerance`, `erp.receipt_tolerance` and
`erp.match_tolerance`. `requisition_required` and
`direct_order_threshold_minor` would refuse MRP, drop-ship, intercompany and
blanket orders; a goods receipt has no approval state; and the auto-approve
threshold would approve an offsetting requisition by nobody.
**P4** Add `purchase_invoice` to the configured lifecycle.
**P5** Budget six.

### Sales

**S1** No `order_from_quotation` exists anywhere in the repo — verified. Build
the transformation so the customer and every line carry over. The quotation moves
to `accepted` as a derived consequence. This is the most visible defect in a
demo.
**S2** Reseed: `pick`, `despatch`, `invoice` and `close` stop being user
transitions; add `partially_despatched`, which today has no equivalent so a
part-shipped order sticks at `confirmed`
(`20260914064000_a_delivery_comes_from_its_order.sql:549-551`).
**S3** Derive all four from posted deliveries, issued invoices and allocation.
**S4** Credit is approved twice: step 3 of `sales_order_terms` at commitment, and
the identical condition again at fulfilment through
`check_release_to_fulfilment()` (`20260914074000_credit_and_the_last_open_items.sql:246, 318`).
Keep one — the commitment one — and make the fulfilment check a
tolerance-gated exception rather than a second approval.
**S5** Step 1 `sales_manager` has no condition, so it fires on every order at any
value (`20260904150000_document_spine_through_promotion.sql:2257-2258`). Give it
a threshold. Set `tolerance_pct` and `tolerance_absolute` on the chain — both
null today, which the engine treats as "any change invalidates"
(`0014_b4_approval_engine.sql:383-385`), so a penny forces full re-approval.
**S6** Publishing one invoice takes `issue_sales_invoice`,
`complete_document_issue` and `mark_document_issue_sent` plus the `issue`
transition. Collapse to one action; keep the others as internal routines.
**S7** Quotation `send`, `accept`, `decline`, `expire` model things that happen
in email. Make them flags.
**S8** Procurement has `erp.receipt_tolerance`; sales has no over or under-ship
tolerance at all. Add the mirror.
**S9** Budget seven.

### Manufacturing

**M1** There is no state machine for manufacturing — verified. Production uses
the bare enum `erp.works_order_status` (`20260829270000_production.sql:81`) with
transitions hard-coded in function bodies, so it has no transition codes and no
audit through the state transition log. Author it as configuration like every
other cycle.
**M2** `close_works_order()` (`:1130-1177`) computes a variance into jsonb and
posts nothing. Accounts 5100 WIP, 9200 material usage variance and 9300 labour
efficiency variance are created at `:1238-1243` and unreachable. Add the posting
rule, a `document.works_order.posted` event, WIP absorption and variance
postings. This is the headline defect of the cycle and the one place the price
list promises more than the product does.
**M3** The word `tolerance` does not appear once in the production migration.
`receive_works_order_output()` (`:871`) accepts any quantity. Add yield, scrap
and over/under-completion tolerances. `release_works_order(p_allow_shortage)`
(`:445`) is a boolean override and is not a tolerance — replace it.
**M4** Fold release into firming. `firm_planned_order()`
(`20260906133000_...:562-612`) already transforms correctly; release adds a
click for work derivable at raise time. Shortage becomes an exception path.
**M5** Backflush exists at `:786-800` and the config type defaults to it at
`:1205`, but the installer promotes `manual`. Install the default.
**M6** `raise_inspection()` has no public door at all, and its only callers are
goods receipt and a test, so no screen can raise an inspection and in-process and
pre-release trigger points are unreachable. Add the door and the production
plans. Separately, `release_batch()`
(`20260829290000_quality_logistics.sql:253, 280-287`) demands typed basis and
signature on every batch including the clean path — require them only where a
plan sampled the batch.
**M7** Remove dead states: `planned` and `cancelled` on works orders, `reviewed`
and `firmed` on planned orders, and the unused `production_event` kinds
`started`, `completed`, `deviation`.
**M8** Budget four.

### Inventory

**I1** The base type `count` exists in reference data and no installer ever
creates a tenant document type from it, so a count has no number, no lifecycle,
no document authorisation and no printable sheet. Install it.
**I2** Counting is three buttons on an audit page. Give counters a worklist they
work down, so a fifty-task programme is not 150 actions.
**I3** A count inside tolerance still costs a second click, because
`record_count()` sets `approved` but `post_count()` refuses anything not
approved and nothing schedules it. Auto-post inside tolerance.
**I4** `raise_stock_adjustment()` (`20260918810000_an_adjustment_carries_its_date.sql:401`)
takes hand-typed lines with no link to the count task that produced the variance.
Make the adjustment a transformation of the count, and use the ten
`STOCK_ADJUSTMENT` reason codes instead of the bare string `'count_variance'`.
**I5** Neither `transfer_order` nor `stock_adjustment` has an approval chain —
approval is a bare state transition on a permission. Add a chain with a value
threshold.
**I6** There is no Approve button on either inventory screen
(`src/routes/inventory/transfers.tsx:80-147`, `adjustments.tsx:85-160`), so
approving means leaving for `/documents/$documentId`. Add it, and cut the module
page from twenty-plus top-level actions (`src/lib/modules.tsx:596-1120`) to the
three a warehouse does daily, with the rest behind an exceptions drawer.
**I7** `closed` on `transfer_order` has no permission and no caller anywhere
(`20260917130000:1207`). Derive it.
**I8** Budgets: one action per count task, three for a transfer.

### Finance

The strongest area. Automatic posting on committed states
(`20260829370000_transition_context.sql:179-193`), automatic tolerance-driven
three-way matching, and derived `paid` are all already right. Do not disturb
them.

**F1** Period close is 8 actions per ledger per period, and `configure_finance()`
opens 12 periods for both GL and COMMIT
(`20260906080000_a_company_is_configured_on_its_own.sql:573-580`), so a month is
16 actions, or 24 with consolidation. Run the six checks automatically on
opening the close, and close all ledgers together. Target two actions.
**F2** The purchasing tile and the balance sheet disagree on goods received not
invoiced by about £957, and neither says which question it answers — likely
as-at date against open. Label both, or reconcile them, as part of this node.
`grni_reviewed` is a pure tick with no blocking check
(`20260918510000_an_ageing_agrees_with_the_ledger.sql:700-703`). Give it one.
**F3** No payment variance, FX difference or rounding tolerance exists anywhere,
and `apply_cash_to_item()` refuses any overpayment outright. A penny short does
not settle an invoice. Add all three.
**F4** No `part_paid` state on either invoice machine, so a part-paid invoice is
indistinguishable from an untouched one.
**F5** Cash arrives as a bare subledger write through `erp.apply_cash()`
(`20260919200000_cash_settles_what_it_pays.sql:330`) with no document. Add a cash
receipt and a remittance advice.

### VAT

**V1** `erp.tax_report()` groups determinations; `erp_ref.statutory_output`
carries boxes 1, 4 and 5 only
(`20260906081000_a_country_is_a_pack.sql:225-230`). Compute all nine VAT 100
boxes, with a period and an obligation.
**V2** Export them with a digital link. HMRC API submission is explicitly out of
scope — bridging remains a valid MTD route, so recognition is not needed to sell.

## 8. PR plan

Fourteen PRs. One branch each, short-lived, into main.

- PR0 — The open demonstration catch-up repair. R0.
- PR1 — Enablers. N1, X1, X2, X3. Nothing depends on a cycle; everything else
  depends on this. X2 and X3 will fail against today's tree, which is correct —
  land them asserting-but-tolerated and flip them to blocking in PR9.
- PR2 — Correctness. C1, C2, C3, C4, C5, C6, C7. No flow changes. Ship first
  because it stops the system giving wrong answers.
- PR3 — Wiring. W1, W2, W3, W4. Large behavioural gain, small diff.
- PR4 — Procurement reseed. P1, P2, P3, P4, P5. The pilot for the mechanism.
- PR5 — Sales quick wins. S1, S6, X4. Independent of the sales reseed and worth
  landing early because S1 is what a prospect sees.
- PR6 — Sales reseed. S2, S3, S4, S5, S7, S8, S9.
- PR7 — Manufacturing foundation. M1, M2, M3. The heaviest PR in the plan.
- PR8 — Manufacturing flow. M4, M5, M6, M7, M8.
- PR9 — Dead configuration gate. W5, and flip X2 and X3 to blocking.
- PR10 — Counts. I1, I2, I3, I4.
- PR11 — Transfers and the inventory surface. I5, I6, I7, I8.
- PR12 — Finance. F1, F2, F3, F4, and the C8 spike note.
- PR13 — Cash documents. F5.
- PR14 — VAT. V1, V2.

## 9. Execution order and parallelism

Strict order: PR0, then PR1, then PR2, then PR3. Nothing else may start before
PR3 lands, because W1 changes approval behaviour in every cycle and rebasing a
reseed over it is worse than waiting. W3 may ship as its own small PR straight
after PR0, because it fixes a screen that currently asserts a false control.

After PR3 there are three tracks. **Run them one at a time by default.** Five
migration version collisions in two days showed that parallel branches adding
migrations are green alone and red together. Fan out only if the wave is built
as one replay before merge.

- Track A, commerce: PR4, then PR5, then PR6.
- Track B, manufacturing: PR7, then PR8.
- Track C, inventory and finance: PR10, PR11, PR12, PR13.

PR9 runs only when tracks A and B have landed, because W5 depends on M7.
PR14 depends only on C1, so it can run any time after PR2.

If you are working alone rather than fanning out, take the tracks in the order
A, C, B — commerce is the demo, inventory is the volume complaint, manufacturing
is the largest build and blocks no revenue once the outbound list is segmented.

## 10. Global acceptance gates

The programme is done when all of these hold. They are the regression suite for
the doctrine itself.

- Every cycle has a declared step budget and an assertion enforcing it.
- No public door writes a document state outside a declared transition.
- Every seeded state is reachable and every seeded transition has a caller.
- `erp.assert_no_dead_configuration()` covers the full register and passes.
- In every cycle, an unchanged child document inherits its parent's approval and
  requests no second one.
- In every cycle, the terminal state is reached with no user transition.
- No cycle exceeds fifteen parameters, and every default produces the clean path.
- The VAT report and the ledger agree on the one-button bill route.
- A works order closes with a journal.

## 11. What this plan does not cover

Named so they are not silently assumed.

- Logistics beyond two carriers. `configure_logistics()` installs carrier config
  and nothing else — no document, no lifecycle, no numbering, four unreachable
  shipment statuses. Out of scope here; needs its own spec.
- Requisition sourcing across multiple suppliers.
- Landed cost and duty apportionment.
- Supplier onboarding and credit control as a module.
- HMRC API submission and MTD recognition.
- Migration and cutover testing against a real legacy dataset.

None of these may add a step to any budget in section 9 when they are built.
