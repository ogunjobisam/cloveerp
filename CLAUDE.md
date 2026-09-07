# Clove ERP

TanStack Start + React 19 + Tailwind 4 + Supabase (PostgreSQL 17.6).
Package manager is **bun**, never npm.
Connected to Lovable: never force-push, rebase, amend or squash pushed commits.

## Read this before exploring

277 migrations, 52 route files, 209 assertion functions, 179 source files.
Do not scan the repo to orient yourself — everything you need is below.
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
- The client gate is `hasPermission(session, "module.action")` — 21 call sites.
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
