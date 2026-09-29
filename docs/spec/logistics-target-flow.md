# Clove ERP — Despatch and Logistics: target flow

Implementable spec. Held to `docs/spec/flow-doctrine.md`, and written as the
companion `docs/spec/simplification-review.md` §11 asked for: "Logistics beyond
two carriers ... needs its own spec."

Status: target state, approved 29 September 2026 with option A for settlement
(section 7). Not what is built today. Section 1 records
the gap, read from a database built from `main` at 2ac3961b.

## 0. Instruction to the implementing agent

- The working rules of `simplification-review.md` §2 bind here unchanged:
  verify against the migrations, no new tables, lifecycle changes as change
  sets, assertions before screens, never add a step, one branch at a time.
- The precedent to copy is the count sheet: `20260927000000` (a count task
  moves by its lifecycle) and `20260927100000` (a count has a sheet). An
  operational table keeps its detail; a document on the spine gives it a number,
  a lifecycle, document authorisation and a printable form, linked by columns.
- If a node's spec is wrong against the tree, stop and say so in the PR rather
  than improvising.

## 1. What is wrong today

Read from `20260829290000_quality_logistics.sql` (the doors), `src/lib/modules.tsx`
(`LOGISTICS`, the Despatch screen), and a local build.

The shipment is a side table with an enum, not a document:

- `erp.shipment.status` is `erp.shipment_status` (line 744): planning, planned,
  tendered, booked, despatched, delivered, exception, cancelled. Three doors
  write it directly: `plan_shipment` (planned), `book_shipment` (booked) and
  `record_proof_of_delivery` (delivered). Nothing writes tendered, despatched,
  exception or cancelled. Planning is transient inside one statement.
- Because it is not a document, §10 gate 2 ("no public door writes a document
  state outside a declared transition") and gate 3 (reachability) never see it.
  The gates pass while four of its eight states are unreachable.
- No number. `plan_shipment` writes `'SH-' || to_char(clock_timestamp(), ...)`,
  a timestamp that two planners in one millisecond collide on.
- No document authorisation, no printable delivery or consignment note, no
  output template.
- Proof of delivery is accepted from any state, including one never booked.

The screen offers presses that cannot complete or that re-type what is known:

- **The carrier picker is empty.** Book a shipment lists `erp_parties('carrier')`,
  parties with a carrier role. `configure_logistics()` installs rows in
  `erp.carrier` and creates no party, so an organisation that installed
  logistics sees no carrier to book. `book_shipment` then looks the code up in
  `erp.carrier`, so a carrier typed as a party only works if its code happens to
  match.
- **The shipment list never names its carrier.** `public.erp_shipments`
  (`20260830014600`, line 44) joins `sh.carrier_id` to `erp.party`; it is a key
  of `erp.carrier`. The carrier column is always empty.
- **Select, then re-type.** Select a carrier computes a recommended carrier,
  service and cost from the rate card; Book a shipment then asks for all three
  again by hand, cost required, service as free text. That is the describe-step
  and re-entry defect (doctrine 2).
- **The strip's first step offers deliveries it cannot ship.** Its Delivery stage
  lists deliveries in `draft`; `plan_shipment`'s picker,
  `erp_deliveries_to_ship` (`20260914075500`), offers only `posted` ones.
- **The strip claims what nothing does.** "The carrier's cost is added to the
  value of the stock it carried" (`modules.tsx:4187`). Nothing reads
  `shipment_line.freight_share_minor`. Outbound freight is a selling cost, not
  stock value; inbound landed cost is out of scope (`simplification-review.md`
  §11).

Settlement has no door:

- The booked freight cost is recorded and apportioned by weight, and posts
  nothing. A carrier's bill cannot be entered at all: the only door that
  registers a supplier bill is `erp_bill_from_receipt`, and a carrier bills for
  a service with no goods receipt. Expected against actual freight (Foundation
  Specification §7.9) cannot be measured.

The demonstration never installs logistics. Nothing but its own public door
calls `configure_logistics()` (the suites aside), so the Despatch screen
and delivery performance are empty for every prospect.

Budgets: `erp_meta.flow_budget` holds despatch at four presses, "to hold the
line rather than to be lowered". The cycle declares no parameters.

## 2. The four events

Doctrine rule 1, for the despatch cycle. The delivery is the sales cycle's
fulfilment and stays there; this cycle starts where it ends.

- **Intent**: the posted delivery, goods issued and waiting at goods-out.
- **Commitment**: the shipment, booked with a carrier at a cost.
- **Fulfilment**: proof of delivery.
- **Settlement**: the carrier's bill, matched to the booked cost.

## 3. Target happy path

Two presses from posted deliveries to a delivered shipment. Settlement is
section 7.

### Action 1 — Ship these deliveries (logistics.plan)

- One door, `erp_ship_deliveries(p_delivery_ids uuid[], p_planned_despatch date
  default null)`, replaces the three presses Plan, Select and Book.
- Born pre-filled (doctrine 2):
  - the site and customer come from the deliveries;
  - the carrier and service are `select_carrier`'s recommended row;
  - the cost comes from the rate card.
- The planner may override the carrier, service or cost on the same form.
- Opens the shipment document (number `SHP-`) through `erp.open_document()`.
  It enters `booked` in the same statement when a tariff or a cost is known.
- If no active carrier quotes the service and no cost is given, the shipment
  stays `planned` and appears on the exceptions screen. It is not refused.
- One customer per shipment, as today (`CLOVEERP_MIXED_DESTINATIONS` stays).

### Action 2 — Record proof of delivery (logistics.despatch)

- The existing door, on a booked shipment only.
- It takes the shipment to `delivered`, which is terminal. Nothing else closes it.

### What the system does with nobody pressing

- "On its way" is derived, not a state: booked with `planned_despatch` on or
  before today.
- "Late" is derived, not a state: booked with `planned_arrival` passed and no
  proof. It is a flag on the exceptions screen (doctrine 4 and 9).

## 4. Target state machine

Shipment, a document on base type `shipment`, installed as configuration by
`configure_logistics()` and offered to installed organisations as a new version
of the logistics pack.

```
planned ──book (logistics.plan)──▶ booked ──deliver (logistics.despatch)──▶ delivered
   │                                  │
   └──cancel (logistics.plan)──▶ cancelled ◀──cancel (logistics.plan)──┘
```

- `book` is reached from the ship door on the clean path, and by hand only from
  the exceptions screen for a shipment left planned.
- `deliver` is driven by `record_proof_of_delivery` and nothing else.
- `cancel` releases the deliveries, which `erp_deliveries_to_ship` already reads.
- Removed:
  - `tendered`: there is no carrier integration to tender to. When there is,
    tendering is a flag on the booking, not a state.
  - `despatched` and `exception`: both are derived, as section 3 says.
  - `planning`: never visible outside one statement.
- `erp.shipment.status` stays as a mirror kept by the one routine that moves a
  shipment, as `count_task.status` is kept by `erp.move_count_task()`. Nothing
  else writes it. The enum keeps its values, since Postgres cannot drop one,
  and the dead-configuration register records the four as unused.

## 5. Parameters and defaults

One config type, `logistics.shipping_policy`, cycle `despatch`, every default
the clean path. Five parameters against the budget of fifteen:

- `auto_select_carrier` (true). The ship door takes the recommended tariff.
  False asks the planner to choose, which is one field more on the same press,
  not a press.
- `cost_override_tolerance_pct` (10). A cost typed above the rate card by more
  than this is booked with a flag on the exceptions screen. It is not refused
  and it is not an approval.
- `late_after_days` (0). The grace after `planned_arrival` before a shipment
  reads late.
- `proof_required` (true). False makes delivery off-system (doctrine 6): a
  booked shipment reads delivered `late_after_days` after planned arrival,
  derived and logged as the system's move.
- `consolidate` (`customer_day`). The ship door's picker offers the posted
  deliveries of one customer from one site and one day together, ticked.

## 6. Correctness nodes, independent of the flow

These fix defects today and do not wait for the rest:

- A carrier is a party. `install_module_config`'s carrier branch creates or links
  a party with a carrier role and sets `erp.carrier.party_id`. The Book picker
  and `erp_shipments` read `erp.carrier`, joined correctly.
- Proof of delivery refuses a shipment that was never booked.
- The Despatch strip's first stage lists posted deliveries not yet on a shipment,
  the same rows its picker offers.
- The false `howItWorks` line is replaced with what happens.
- The demonstration installs logistics and ships a few of its posted deliveries,
  some delivered on time, one late, so the screen and delivery performance show
  real rows.

## 7. Settlement: option A, decided 29 September

Expected against actual freight needs a carrier's bill in the system, and the
system has no door for a bill without a goods receipt. There are two ways to
give it one. Option A was chosen; B is recorded as the road not taken.

- **A. A service bill against the shipment (chosen).** A purchase invoice
  on the carrier's party, born from a delivered shipment (doctrine 2),
  carrying the booked cost as its expected total. The difference is judged
  against `cost_override_tolerance_pct`: inside it the bill registers, and
  outside it the bill lands disputed and clears through the match exception
  route C7 built. The cost posts to a carriage-outwards account on the bill,
  as a service bill does, with no accrual. This adds one press, Bill from
  shipment, and a despatch budget of three.
- **B. Accrue at booking (not taken).** Booking posts the expected freight to an accrual;
  the bill clears it and the variance posts. It is more complete and it is the
  heavier build: a posting rule on the shipment document, an accrual account
  in the chart packs, and a clearing check at period close. Not taken: A
  measures expected against actual freight without touching the ledger
  twice, and an organisation that wants accruals can ask for B later
  without A being undone.

A still changes procurement's bill door, which is procure-to-pay territory,
so it is its own PR, last. The spike sizes it and confirms the
carriage-outwards account exists in every chart pack; if a pack lacks one,
stop and say so rather than adding an account unasked.

## 8. Nodes and PRs

`needs` lists what must land first. `proves` closes the node.

```yaml
nodes:
  - id: L1
    title: A carrier is a party, and the shipment list names it
    needs: []
    pr: LPR1
    proves: erp_test.logistics_suite - picker lists installed carriers; erp_shipments names the carrier

  - id: L2
    title: Proof of delivery only for a booked shipment; strip lists shippable deliveries; true howItWorks
    needs: []
    pr: LPR1
    proves: erp_test.logistics_suite; e2e - the despatch strip offers no delivery its door refuses

  - id: L3
    title: The shipment is a document - base type, numbering SHP-, lifecycle as configuration
    needs: [L1]
    pr: LPR2
    proves: erp_test.shipment_document_suite; X2 and X3 cover the shipment

  - id: L4
    title: Ship these deliveries - one press, born from the deliveries and the recommended tariff
    needs: [L3]
    pr: LPR2
    proves: erp_test.logistics_suite - planned and booked in one statement; override inside tolerance flagged

  - id: L5
    title: On its way and late are derived; exceptions screen holds planned, late and over-tolerance
    needs: [L3]
    pr: LPR3
    proves: erp_test.logistics_suite; e2e - the exceptions drawer holds only what needs a person

  - id: L6
    title: logistics.shipping_policy - five parameters, defaults the clean path
    needs: [L4, L5]
    pr: LPR3
    proves: erp.assert_parameter_budget - despatch holds five

  - id: L7
    title: Despatch step budget of two, walked
    needs: [L4, L5]
    pr: LPR3
    proves: erp_test.step_budget_suite - despatch walked in two presses by a planner and a driver who are not administrators

  - id: L8
    title: The demonstration ships
    needs: [L7]
    pr: LPR3
    proves: demonstration Despatch screen and delivery performance show real rows

  - id: L9
    title: Freight settlement - option A, a service bill born from the delivered shipment
    needs: [L7]
    pr: LPR4
    proves: erp_test.freight_settlement_suite; the despatch budget walked at three, Bill from shipment the third press
```

PR order, one at a time: LPR1, LPR2, LPR3, then LPR4. LPR1 is
small and fixes a screen that cannot complete today, so it can ship on its own.

## 9. Acceptance

The cycle is done when all of these hold. They join the §10 gates.

- The shipment is on the document spine. Gates 2 and 3 cover it, and every one
  of its states is reachable.
- Despatch is two presses from posted deliveries to delivered, and three to a
  registered carrier's bill, walked in `erp_test.step_budget_suite`; the strip
  draws no more.
- Expected and actual freight are both recorded, and a bill outside the
  tolerance lands disputed rather than posting.
- No press re-types what the system knows: carrier, service and cost come from
  the rate card unless overridden.
- The despatch cycle holds at most fifteen parameters, each defaulting to the
  clean path.
- The demonstration shows shipments, one of them late.

## 10. Out of scope

Named so they are not assumed, and so none adds a step to section 9's budget
when built:

- Carrier integration: labels, tracking capture, status webhooks, electronic
  proof of delivery.
- Customs and cross-border documents, commodity codes, duty estimation.
- Groupage and multi-drop loads, load building, route planning.
- Inbound freight and landed cost onto item cost.
- OTIF by site and failed-delivery analysis beyond what `delivery_performance`
  already reports.
