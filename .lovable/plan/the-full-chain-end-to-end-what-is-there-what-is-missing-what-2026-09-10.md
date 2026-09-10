# The full chain, end to end — what is there, what is missing, what to build

I have checked the described chain against what the system actually does today.
Most of it exists. The gaps are specific, and they are the joins between steps —
which is exactly where the work currently feels clunky.

## Already working

Companies, sites and locations; suppliers and customers; requisitions, purchase
orders, goods receipts, supplier bills and payment runs; put away and picking
against real warehouse rules; sales orders, allocation, despatch and invoices;
batches, expiry horizon and stock counts; the ledger, chart of accounts,
dimensions, account determination and period close; composable job roles.

## The gaps, in the order they bite

### 1. Requisition to purchase order
There is no way to turn an approved requisition into a purchase order. Today you
retype it. **Build:** a **Convert to purchase order** button on an approved
requisition that copies supplier, lines, quantities and prices onto a new order,
links the two documents, and marks the requisition converted. You choose when —
nothing happens automatically. Part-conversion (order some lines now) included.

### 2. Approval on the requisition itself
Approval routing exists but requisitions do not use it. **Build:** submit for
approval, approve/reject with a reason, and a "waiting on me" list, using the
existing approval bands so value thresholds already configured apply.

### 3. Under and over delivery
A receipt currently accepts any quantity. **Build:** per-supplier and per-item
receipt tolerance (percentage or quantity, over and under). Within tolerance the
line closes short and the order closes; outside it, the receipt is refused unless
someone with the right permission accepts the exception, which is recorded. A
short-closed line can be reopened.

### 4. Stock statuses
Stock is either there or not. **Build:** a status on each stock holding —
available, quarantine, damaged, on hold, awaiting inspection — set on receipt
(quality-controlled items land in quarantine), changed by an explicit
**Change stock status** action, and respected by picking and allocation so held
stock is never taken. Statuses are tenant-configurable.

### 5. Batches, expiry and use-by
Batches exist, but nothing forces them. **Build:** an item flag for batch-tracked
and expiry-tracked; receipt then requires a batch and its expiry/use-by; picking
takes shortest-life-first; expired stock cannot be allocated; a shelf-life alert
on the forecast and stock screens.

### 6. Moves between locations and sites
**Build:** a **Move stock** action (from location, to location, quantity, batch,
reason) and an **Inter-site transfer** document: raise, despatch from the sending
site, receive at the receiving site, with stock in transit visible between the
two and the ledger entries on both sides.

### 7. Allocation you can override
Stock allocated to a sales order is currently untouchable. **Build:** allocation
priority on the order, a **Reallocate** action that takes stock from a lower
priority order (recorded, with the losing order flagged), and a soft/hard
allocation setting so soft allocations can be broken freely.

### 8. Reordering that reflects reality
The forecast already measures usage and real supplier lead times. **Build:**
economic order quantity, order multiples, minimum order quantity, safety stock by
service level, and a reorder policy per item and site — with the suggested order
quantity on the forecast obeying all of them, and the workings shown.

### 9. Location types
Locations exist but their type is implicit. **Build:** location types
(goods in, bulk, pick face, quarantine, despatch, transit) on the warehouse
screen, with put away and picking honouring them.

### 10. Sales chain, made continuous
Order to general allocation to shipment to detailed allocation to despatch to
posting to invoice is all present but scattered across screens. **Build:** one
sales chain on the sales screen where each step hands to the next, with the
document staying in view throughout — the same shape as the purchasing chain.

### 11. Roles and permissions, made obvious
**Build:** a role screen that shows what each job role can actually do in plain
words, a "who can do this?" lookup per action, and copy-a-role so a new role
starts from an existing one.

## How I would sequence it

Each phase is independently usable, so you can walk the flow after each.

1. **Purchasing joins** — items 1, 2, 3
2. **Stock truth** — items 4, 5, 9
3. **Movement** — items 6, 7
4. **Planning** — item 8
5. **Sales and people** — items 10, 11

## Technical notes

- New governed routines: `erp_convert_document`, `erp_submit_for_approval`,
  `erp_receipt_tolerance` (+ upsert), `erp_set_stock_status`, `erp_move_stock`,
  `erp_create_transfer`, `erp_reallocate`, `erp_upsert_reorder_policy`. Each
  asserts its own governance in the same migration, per the boundary check.
- Stock status and batch enforcement go on `erp.stock_balance` /
  `erp.stock_movement` with the picking and allocation resolvers extended, not
  replaced — no change to posting logic.
- All new screens use the existing process-flow workbench and full-page forms, so
  nothing new appears in the interface vocabulary.
- Migrations are forward-only; each re-runs the generators and adds an
  `erp_test.assert_*` covering the new rule, so the build proves it.
- Verification per phase: `bun run typecheck`, `bun run lint`, `bun run test`,
  `bun run build`, plus a walk of the affected chain in Clove Foods.
