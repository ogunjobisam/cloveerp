# ERPWare: audit findings and what to fix

I signed in as the test admin and walked every page in the app, watched the network and console, and compared the database's curated API against what the UI calls. The shell, tenant switching, permissions, configuration and the operations pages all work. The transactional half of the product does not — and the app currently hides that behind reassuring empty states.

## What is broken right now

**1. Sales and Procurement are dead, and they lie about why.**
Both pages call two database functions that do not exist: `erp_document_types` and `erp_currencies`. Every call 404s. The UI treats the failure as "empty" and renders *"No quotation type is configured for this tenant. Install the module that owns it on Configuration."*

That message is false. The demo tenant has 13 promoted change sets and **8 document types already configured**. A user reading this will go install modules that are already installed, and conclude the product is broken in a way it isn't.

**2. Even with those two fixed, the document journey still cannot complete.**
Three more functions the UI calls are missing from the database:
- `erp_parties` — the customer/supplier picker on "New document"
- `erp_items` — the item picker on "Add line"
- `erp_available_transitions` — the buttons that move a document through its lifecycle

So: cannot create a document, cannot add a line, cannot confirm one.

**3. There is no master data, and no way to create any.**
`erp.item` and `erp.party` are both empty, and there is no public function to create either. Even with every picker fixed, there is nothing to pick. This is the single biggest gap: an ERP with no items and no customers has no transactions.

**4. Assurance reports every check as "Violated".**
All structural assertions fail with `permission denied for schema erp_meta`. This is a grant problem, not a real violation — but the page currently tells you the platform is structurally broken, which is worse than showing nothing.

**5. The one-click demo seeds a shell, not a demo.**
It creates a tenant, two entities, three sites and two principals. No items, no customers, no suppliers, no documents. So "explore the UI immediately" lands on a set of empty tables.

## What is missing rather than broken

The database exposes ~120 curated `erp_*` functions. The UI uses 17. Whole modules have a backend and no screen at all:

- **Inventory** — stock health, valuation, ageing, counts, write-offs, batches, expiry
- **Finance** — trial balance, receivables ageing, dunning, payment runs, period close, tax
- **Planning** — planner workbench, forecast, run planning, available-to-promise
- **Production** — works orders, issue/receive, operation booking, variance
- **Quality** — inspections, quality events, recalls, batch genealogy
- **Master data** — items, parties, data quality, duplicates, mass change, imports
- **User administration** — `erp_invite_principal` and `erp_create_service_principal` exist, but the only way to invite someone today is to paste a token you have no way to generate from the UI
- **Go-live** — `erp_go_live` exists with no screen, so separation of duties can never be switched on

## Usability issues found during the walk

- Failed requests render as empty states. A 404 and "no data" look identical, which is how issue 1 stayed invisible.
- The invitation flow is half-built: redeem exists on the onboarding screen, issue does not exist anywhere.
- Scope (entity/site) is selectable but nothing on the current pages narrows by it, so it reads as a broken control.
- No global search, no breadcrumbs, no way back from a document to its list other than the nav.

## Proposed order of work

**Phase 1 — make the existing screens honest and working**
1. Add the five missing database functions: `erp_document_types`, `erp_currencies`, `erp_parties`, `erp_items`, `erp_available_transitions`, all tenant-scoped and permission-checked like the existing ones.
2. Fix the `erp_meta` grants so Assurance reports real results.
3. Change the data panels to distinguish "this failed" from "this is empty", showing the database's message and hint.

**Phase 2 — master data**
4. Add `erp_create_item`, `erp_create_party` (plus list/search) and an `/master-data` screen for items and parties.
5. Extend the demo seed to create items, customers, suppliers and a couple of live documents, so the demo actually demonstrates.

**Phase 3 — close the administration loop**
6. Invite screen on Permissions using `erp_invite_principal`, showing the token to hand over, plus service principals.
7. Go-live screen using `erp_go_live`.

**Phase 4 — the missing modules**
One screen per module, in the order you care about. My suggested order is Inventory, then Finance, then Planning, Production, Quality — each following the existing panel/table conventions.

## Technical notes

- New functions go in `public` as `SECURITY DEFINER` with `search_path = ''`, tenant-scoped through `current_tenant_id()` and gated by `erp.authorise(...)`, matching `erp_permissions_directory`. No new table exposure to PostgREST.
- Frontend changes stay in `src/components/erp/*` and `src/routes/*`, reusing `DataPanel`, `Table`, `Pill` and the `Action` picker.
- The error/empty distinction is one change in the panel component plus the `ErpError` fields (`code`, `details`, `hint`) that `src/lib/erp.ts` already captures but does not display.

Tell me which phase to start with — Phase 1 alone would make Sales, Procurement and Assurance truthful, and is the prerequisite for everything else.
