# Production readiness: full journey sweep and fix pass

Goal: walk every user journey in the running app as a real signed-in user, record what breaks, and fix everything found — blocking defects and rough edges alike.

## How the sweep runs

Driven through a real browser against the running app, signed in as the owner account, with the console and network recorded on every screen. Each journey is walked as a person would walk it, not just loaded.

Recorded per screen: page errors, failed requests, permission failures, empty states that should have data, dead controls, and anything that reads as unfinished.

## Journeys to walk

1. **Arrival and sign-in** — landing page, product page, email sign-in, Google sign-in path, sign-out, profile and settings.
2. **Onboarding** — create a tenant, seed the demo tenant, redeem an invitation, the onboarding interview.
3. **Platform console** — companies, staff, activity, plans, incidents, queue, diagnostics, deployment, ownership transfer, suspension and purge.
4. **Plan** — planning board, forecasting, planner workbench.
5. **Source** — procurement: order, receive against it, match, supplier records, landed cost.
6. **Make** — production: raise, release, issue, receive, close a works order; book time; batch record.
7. **Move** — inventory and logistics: counts, write-offs, batches, warehouse tasks, release areas, waves, shipment and delivery.
8. **Sell** — sales: quote to order, reserve, price, promise, credit position, despatch, returns.
9. **Settle** — finance: invoicing from delivery, cash application, payment runs, period close, account determination.
10. **Quality** — inspections, dispositions, quality events, recall readiness.
11. **Master data and governance** — items, parties, classification, change requests and approvals, imports, mass change.
12. **Administration** — permissions, configuration, terminology, audit log, packs, commercial, adoption, accessibility, erasure, tenant lifecycle.
13. **Operations** — jobs, integrations, devices, output, continuity, cutover, assurance.
14. **Device client** — the bare warehouse screen, including queued-offline behaviour.

## Fix pass

Everything found is fixed in the same pass, ordered:

1. Anything that stops a journey: errors, failed calls, permission failures, controls that do nothing.
2. Correctness: wrong numbers, stale reads after an action, actions that succeed but do not refresh the screen.
3. Presentation: raw error text, missing empty states, untranslated literals where a resource key exists, keyboard and contrast problems.

Where a journey cannot be walked because the demo tenant has no data for it, the demo seed is extended so the journey has something to act on — through the same governed functions the interface uses.

## Production-readiness checks alongside the sweep

- Database security lint and security scan; every critical finding either fixed or explained.
- Row-level security and grants confirmed on every table the interface reads.
- Build, typecheck, lint and the existing unit tests all clean.
- Page metadata (title, description, social preview) present and distinct on every public route.
- Migration registry reconciled against the repository so live and repo agree.

## Deliverable

A short written report of what was walked, what was found, what was fixed, and anything deliberately left — with the app in the fixed state.

## Technical notes

Browser automation runs against the local dev server with the owner session restored. Fixes stay in the frontend where the defect is presentational; backend fixes go through migrations, never direct edits to generated types or migration files. The seed extension, if needed, is a single migration extending the existing demo seed.
