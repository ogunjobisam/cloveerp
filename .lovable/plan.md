# ERPWare functional audit — 30 August 2026

I signed in as the admin account, walked all 23 routes, watched console and network on each, and compared the database's curated API against everything the interface actually calls.

## What is now healthy

- Every route loads. No console errors, no failed requests, no permission failures anywhere in the sweep.
- The 405 failures found in the previous audit are gone: no read function is still declared read-only while calling the authorisation gate.
- Every function the interface calls exists in the database. No broken calls remain.
- Platform console (companies, staff, activity, ownership transfer), permissions, configuration, terminology, audit log, governance, imports and tenant lifecycle all work.
- The build is clean.

## The two real gaps

**1. There is almost no data, so most screens are honest but empty.**
Across the whole database there is 1 item, 1 party, 1 document, 0 stock movements and 0 works orders. Consequently Production, Planning, Quality, Logistics, Inventory and much of Finance render "Nothing recorded yet" everywhere. The dashboards are correct; there is simply nothing for them to report. The demo seed creates structure (tenants, entities, sites, principals, a couple of documents) but no operational history.

**2. Roughly half the backend has no way to be driven from the interface.**
155 curated functions exist; 73 are wired up and **82 are not**. The unwired ones are overwhelmingly the *doing* verbs, which is why nothing generates data:

- Procurement: receive against an order, three-way match workbench, supplier qualification, landed cost.
- Sales: reserve stock for a line, price resolution, promise date, credit position and hold release, customer returns.
- Production: raise / release / issue to / receive from / close a works order, book operation time, variance.
- Inventory: raise and record counts, post counts, write off stock, split and release batches, redistribution.
- Planning: run planning, run and sign off forecast, planner workbench, supply and demand, available-to-promise.
- Quality: record inspection results, disposition, raise quality events and recalls, recall readiness and evidence.
- Logistics: plan shipment, select carrier, book shipment, proof of delivery.
- Finance: open and close period, close tasks, payment run proposal and approval, cash application, invoicing from delivery, budget position.
- Master data: change requests via the governed path, mass change, merge duplicates, import staging and preview.
- Administration: invite a principal, create a service principal, kill switches, job triggers, message replay.

Everything else (per-tenant encryption keys, cryptographic key destruction, full resource-key coverage, the relaxed tenant switcher) is unchanged from the last review and remains a deliberate deferral.

## Proposed order of work

**Phase A — make the demo demonstrate.**
Extend the demo seed so a seeded tenant has real history: items with stock, receipts posted, a works order completed, a shipment despatched, invoices raised and a period part-closed. Every existing dashboard then shows real numbers with no UI change.

**Phase B — close the operating loops, one journey stage at a time.**
Add the action controls to the existing module pages, in journey order, so each stage can be driven end to end:
1. Source: receive against order, match workbench.
2. Make: raise → release → issue → receive → close works order, book time, variance.
3. Move: counts, write-off, batch actions, shipment planning and despatch.
4. Sell: reserve, price, promise, credit hold, returns.
5. Settle: period open/close, close tasks, payment runs, cash application, invoicing.
6. Plan: run planning and forecast, planner workbench.
7. Quality: inspections, dispositions, events, recalls.

**Phase C — administration completeness.**
Invite a principal and create a service principal from Permissions; kill switches, job triggers and message replay on Operations.

## Technical notes

No database changes are needed for Phase B — every function already exists, is permission-gated and correctly volatile. The work is UI: reuse `RpcButton` / `Action` with the existing argument-picker pattern, place them on the module pages defined in `src/lib/modules.tsx`, and gate each by the permission code the function already enforces. Phase A is a single migration extending `erp_seed_demo` to post movements and documents through the same governed functions the UI will use, so the seed exercises the same paths.
