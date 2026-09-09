# Clove ERP

TanStack Start + React 19 + Tailwind 4 + Supabase (PostgreSQL 17.6).
Package manager is **bun**, never npm.
Connected to Lovable: never force-push, rebase, amend or squash pushed commits.

## Read this before exploring

This repository is large: hundreds of migrations, hundreds of assertion
functions, dozens of routes. Do not scan it to orient yourself — everything you
need is below. (No figures are quoted here on purpose: a number nothing checks
is a number that drifts. `docs/build_counts.sh` holds the ones that are checked.)
If a path here is wrong, say so and ask. Do not go looking.

## Where things live

- `src/routes/<area>/` — the ERP areas: administration, commercial, documents,
  finance, governance, inventory, logistics, master-data, operations, planning,
  procurement, production, quality, reporting, sales. TanStack file routes.
- `src/components/erp/` — the desk: `gate.tsx` (auth boundary), `shell.tsx`,
  `module-page.tsx`, `panel.tsx`, `record-browser.tsx`, `command-palette.tsx`.
- `src/components/platform/` — the vendor console. Separate role model
  (`PlatformRole` = owner | operator | support in `src/lib/platform.ts`).
- `src/components/ui/` — shadcn primitives. Do not edit; wrap them.
- `src/lib/erp.ts` — the Supabase client, `callErp()`, `hasPermission()`.
- `supabase/migrations/` — forward-only, immutable once pushed.
- `supabase/ci/` — the build's own checks. Read these before writing a new one.
- `supabase/ops/` — the operator's runbook: equivalence checks, live
  reconciliation, one-off routines. Not part of the build.
- `supabase/functions/` — `dispatch`, `enquiry` (Deno).
- `worker/` — the dispatch worker (Bun).
- `docs/ARCHITECTURE.md` — carries figures checked against the built database.

## Commands

- `bun install --frozen-lockfile`
- `bun run typecheck` — strictest tsconfig in the repo
- `bun run lint`
- `bun run test` — `bun test src`
- `bun run build`
- `bun run dev`
- Edge Functions: `deno check --import-map supabase/functions/import_map.json supabase/functions/*/index.ts`
- Schema assertions: `supabase/ci/run_checks.sh` against a locally built database

## How to verify work — read this before checking anything by hand

The build already proves most of what you would be tempted to check manually.
`.github/workflows/schema.yml` stands the schema up from an empty cluster on
every pull request and runs every `erp.assert_*` and `erp_test.assert_*` in
`erp.ci_check_catalogue()` — a check that exists and is not run fails the build.

**Do not walk the UI role by role to verify permissions.** That behaviour is
already asserted by:

- `erp_test.assert_grant_suite`
- `erp_test.assert_door_isolation_suite`
- `erp_test.assert_refusal_register_suite`
- `erp.assert_document_create_permissions`
- `erp.assert_governed_views_are_safe`, `erp.assert_authorising_doors_are_volatile`

If you believe a permission is wrong, extend an assertion — do not click
through screens. A defect that a suite cannot see is a missing suite.

A change is done when `bun run typecheck`, `bun run lint`, `bun run test` and
`bun run build` pass. Do not verify by reading files back.

## The permission model

- There is no role enum. Roles are tenant data: principal → grant → role →
  permission codes like `administration.roles`, `sales.order`, `finance.post`.
- The client gate is `hasPermission(session, "module.action")`.
- The database refuses regardless of the UI. Hiding a control is convenience,
  never the enforcement. Never add a UI check as the only guard.
- Every table is tenant-scoped and `current_tenant_id()` is resolved by the
  database. Never write a query that could cross tenants.

## Migrations

- Forward-only. Never edit a migration that has been pushed —
  `supabase/ci/migrations_immutable.sh` fails the build for it.
- Every migration ends by re-running the generators (`erp.apply_row_security()`
  and friends). They must be idempotent.
- A new public function must assert its own governance in the same migration —
  `supabase/ci/boundary_in_migration.sh`.
- **`.github/workflows/deploy.yml` is the only way a migration reaches
  production.** Not the connector, not a console, not by hand. On 8 September a
  replay and something else applied the same migrations at the same time and
  met on a `CREATE OR REPLACE`; the deploy lost twenty-three minutes of work to
  a duplicate-key error, and the other writer had already carried on. Two
  routes into one database is how that happens, and only one of them records a
  release, proves the result, or can be rolled back to a known point.
- `.mcp.json` therefore asks for `docs`, `debugging` and `development` only.
  Those read. The groups that write — `database` (`apply_migration`,
  `execute_sql`), `functions` (`deploy_edge_function`), `branching`, `account`
  — are not requested, so a session that opens this repository cannot reach
  production by accident. Needing one of them for an incident is a reason to
  add it deliberately and take it out again, not a reason to leave it on.

## Lovable

- `AGENTS.md` is Lovable-managed. Leave it alone.
- Commits on the connected branch sync into the Lovable editor, so keep that
  branch working.
- Never rewrite published history.

## Conventions

- Strict tsconfig: `exactOptionalPropertyTypes`, `noUncheckedIndexedAccess`,
  `noPropertyAccessFromIndexSignature`. No `any`, no `@ts-ignore`.
- Server state via React Query. No `useEffect` data fetching.
- Tailwind 4 only.
- No new dependencies without asking.

## How to work with me

- Plan first for anything touching more than three files. Show the plan, wait.
- For a scoped change, edit and run the checks — do not ask permission per file.
- Never create README or documentation files unless I ask. `docs/` figures are
  checked against the database; adding prose there breaks the build.
