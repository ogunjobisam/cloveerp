# ERPWare — Comprehensive Build Report

Everything that exists today, what it does, and where the gaps remain. Read-only report; no changes proposed.

## 1. What ERPWare is

A multi-tenant ERP built to the Foundation Specification: a React 19 / TanStack Start frontend over an external Supabase project (`ERPWare`, `xpzffnnhnhcqyjqcueja.supabase.co`). All business logic lives in Postgres functions (`erp.*` RPCs); the frontend calls them through one typed gateway (`callErp`) and never touches tables directly. Custom domain: erpware.dev.

## 2. Database layer (the real product)

- **~45 migrations**, the bulk of the build. Organised by domain: procurement, sales, finance posting, master data, inventory operations, planning, production, quality & logistics, posting bridge, document authorisation, reference reads, transition context, part5 coverage, bootstrap/provisioning suites.
- **~170 RPC functions** (the `erp_*` catalog). Highlights:
  - Documents & workflow: `erp_create_document`, `erp_add_document_line`, `erp_available_transitions`, `erp_link_documents`, `erp_document(s)`.
  - Master data: `erp_create_party`, `erp_add_party_role`, `erp_create_item`, governed edits via `erp_open_change_request`, `erp_apply_change_request`, change sets, mass changes, merge/duplicate detection.
  - Inventory: batches, ATP (`erp_available_to_promise`), count tasks/accuracy, expiry horizon, landed cost allocation.
  - Finance: ledgers, fiscal periods, close tasks, budgets, GRNI, match workbench, cash application, dunning, fixed assets, credit position, intercompany.
  - Planning/production/quality: planner workbench, planned orders, works orders, batch records, inspections/dispositions, recalls, excursions.
  - Logistics: shipments, delivery performance.
  - Platform: onboarding (`erp_onboard_tenant`), go-live checks, tenant export, deletion request, platform assurance, integration health/backlog, job health, kill switches, audit.
  - Resource keys: `erp_resources`, `erp_set_resource_override`, coverage report (spec §7).
- **Security model**: tenant-scoped RLS everywhere, effective-dated permission grants, `hasPermission` mirrored client-side only for hiding UI — the database enforces.
- **Self-measurement**: `erp_part5_summary()` / `erp_part5_coverage(section)` report spec coverage (~85% overall; 100% on 5.1, 5.5, 5.8, 5.11).

## 3. Frontend architecture

- **Shell** (`shell.tsx`): permission-derived left rail grouped Home / Operate / Govern / Administer; entity/site scope selectors; mobile drawer below 768px; `ScopeChip` for phones.
- **Module registry** (`lib/modules.tsx`, ~1,100 lines): one declarative list of tiles (path, title key, permission, group, KPIs, panels) that drives the launchpad, rail, module pages and reports — the Fiori-style "one registry, many renderers" redesign.
- **Shared ERP components** (15 files): `Gate` (auth + tenant resolution), `session-context` (single context instance — fixed the HMR duplicate-context crash), `ModulePage`, `Launchpad`, `KPI`, `AutoPanel` (renders any jsonb RPC result as a table), `RpcButton`/`useErpAction` (one button = one RPC, honest failure), `documents`, `panel`, `page`, `seed`, `user-menu`, `branding`, `logo`.
- **Resource keys** (`lib/i18n.tsx`): `ResourceProvider` + `t(key, fallback)`; tenant terminology overrides change text without a build.
- **Friendly errors** (`lib/errors.ts`): Postgres/ERP/auth/network errors mapped to plain-language messages with technical detail collapsed (fixed the raw `duplicate key value violates unique constraint…` screenshots).
- **Branding** (`lib/brand.tsx`, `logo.tsx`, `user-menu.tsx`): uploaded ledger-style mark + Fraunces wordmark; per-tenant overrides via five resource keys (`brand.name.prefix/suffix`, `brand.color.ink/total`, `brand.logo.url`); dynamic favicon; profile menu with tenant switcher, settings links, sign-out.

## 4. Routes (screens)

| Area | Routes | Backed by |
|---|---|---|
| Public | `/` (organic-slate landing), `/product` | static |
| Launchpad | authenticated home | module registry |
| Master data | `/master-data`, `/master-data/imports` | parties, items, change requests, import batches |
| Operate | `/sales`, `/procurement`, `/inventory`, `/planning`, `/production`, `/quality`, `/logistics` | domain RPCs via ModulePage |
| Govern | `/finance`, `/governance`, `/reporting` | ledgers/close/approvals/reports |
| Administer | `/administration/configuration`, `/permissions`, `/terminology`, `/tenant` | effective-dated config, grants, resource overrides, lifecycle |
| Operations | `/operations/jobs`, `/integrations`, `/assurance` | job/integration health, assurance checks |
| Documents | `/documents/$documentId` | document detail + transitions |

Every route has its own `head()` with title/description/OG; root carries sitewide defaults, `/og-image.png`, `favicon.svg`.

## 5. Key decisions made along the way

- External Supabase kept external (not Lovable Cloud) — RLS and RPCs are the product.
- Tenant branding as resource-key overrides instead of a new table (spec §7/§2.3 support it).
- Permission hiding is cosmetic; enforcement is always in Postgres.
- Minor-unit money (`lib/money.ts`, tested), dual timestamps, outbox/audit per spec.

## 6. Verified vs unverified

- **Verified**: typecheck clean, builds OK, all routes return 200, ESLint 0 errors (9 pre-existing Fast Refresh warnings), earlier Playwright runs confirmed sign-in, tenant switching, demo seeding, permissions page, module navigation without console errors.
- **Not verified recently**: authenticated end-to-end run since the branding/metadata/module-registry work; external_unmanaged Supabase means no auto-minted session — a sign-in via preview or `lovable auth-session` is needed.

## 7. Honest gaps (carried from audits, still true)

1. **Spec §2.1 tension**: spec says one user = one tenant; the switcher lists several. Decide: keep multi-tenant or restrict.
2. **Per-tenant encryption keys / key destruction**: not implemented (deletion purges data; no crypto-shredding).
3. **12 database security-lint findings** outstanding (mostly intentional/pre-existing).
4. **Some strings still English fallbacks** rather than seeded resource keys.
5. **Not all ~170 RPCs have UI** — major ones do, but the tail (e.g. landed cost allocation, excursions, mass change) is API-only.
6. **No audit-log screen** for tracking change submissions/approvals by tenant and user (requested earlier, never built).
7. **BrandingPanel** exists and works but check it is wired into `/administration/tenant` as intended.

## 8. Suggested next steps (if you want to continue)

- Run an authenticated end-to-end sweep of all 20 routes and fix what surfaces.
- Build the audit-log screen (gap 6) — the data already exists in change sets/approvals.
- Resolve the one-user-one-tenant question (gap 1).
- Triage the 12 lint findings (gap 3).
