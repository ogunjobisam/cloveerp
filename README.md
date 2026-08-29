# ERPWare

A tenant-neutral, multi-entity ERP platform whose behaviour is configured
rather than coded.

The foundation the specification requires before any functional module — B1
through B10 — is complete, along with a dispatch worker, an application shell,
and procurement as the first module. Procurement adds **no tables**: it is
three state machines, a value-banded approval chain and some numbering rules,
promoted through the change-management engine exactly as a customer's own
change would be. That is the point of the whole exercise.

**→ [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — what exists, how it is
enforced, what it found, and what is still missing.

## State

|                   |                                                                                                     |
| ----------------- | --------------------------------------------------------------------------------------------------- |
| Foundation B1–B10 | Complete — 49 migrations, ~25,100 lines of SQL                                                      |
| Modules           | Procurement (requisition → purchase order → receipt)                                                |
| Runtime           | Dispatch worker: outbox, command queue, scheduler                                                   |
| Verification      | 11 structural assertions, 4 adversarial suites (81 cases), run from an empty database on every push |

## Running it

```sh
bun install
bun run dev
```

Point it at a Supabase project with `VITE_SUPABASE_URL` and
`VITE_SUPABASE_PUBLISHABLE_KEY`.

### The database

```sh
psql -f supabase/ci/00_host_bootstrap.sql
for f in supabase/migrations/*.sql; do psql --single-transaction -f "$f"; done
```

`supabase/ci/00_host_bootstrap.sql` is everything ERPWare expects from its
host — the extensions schema, three roles, and `auth.uid()`. Roughly eighty
lines, and it is the honest answer to "how much of this is locked to Supabase".

### The worker

```sh
cd worker && bun install && bun run src/main.ts
```

It holds the credentials the database deliberately does not. See
[worker/README.md](worker/README.md).

## Verifying it

```sh
psql -c "select erp.assert_isolation();"
psql -c "select erp_test.assert_isolation_suite();"
```

Every claim the specification makes in prose is a callable function that fails
the build. If an assertion raises, the migration that called it rolls back.

## Layout

```
supabase/migrations/   the product — a PostgreSQL schema
supabase/ci/           what it expects from its host
worker/                the dispatch worker
src/                   the application shell
docs/ARCHITECTURE.md   the reference
```
