# Clove ERP

A tenant-neutral, multi-entity ERP platform whose behaviour is configured
rather than coded.

The product is a PostgreSQL schema. Every rule the specification states in
prose is a callable function that fails the build; every screen calls a named
door on a curated public API; every door either has a screen or a register row
saying who calls it instead. The application, the dispatch worker and the
status page sit outside the database and hold what it deliberately does not.

**→ [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — what exists, how it is
enforced, what it found, and what is still not proven.
**→ [docs/Clove_ERP_What_Has_Been_Built.docx](docs/Clove_ERP_What_Has_Been_Built.docx)**
— the same account as a document, regenerated from the build.

## State

The figures below are read from the built database by `docs/build_counts.sh`
and checked on every push; the words around them are written by a person.

|                        |                                                                                                                                                                                                                                        |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Specification          | <!-- count:spec_version -->v1.6<!-- /count -->, Parts 1–23; every product decision D1–D<!-- count:product_decisions -->41<!-- /count --> registered and bound to the check that enforces it                                            |
| Schema                 | <!-- count:migrations -->269<!-- /count --> migrations, <!-- count:erp_tables -->238<!-- /count --> tenant tables, <!-- count:ref_tables -->69<!-- /count --> product-content tables, <!-- count:meta_tables -->63<!-- /count --> platform tables |
| Public API             | <!-- count:doors -->543<!-- /count --> doors, every one with a screen or a registered caller; <!-- count:doors_pending_screen -->2<!-- /count --> waiting for a screen                                                                 |
| Part 5 capabilities    | <!-- count:part5_built -->96<!-- /count --> built, <!-- count:part5_partial -->0<!-- /count --> partial, <!-- count:part5_absent -->1<!-- /count --> absent by a recorded decision, of <!-- count:part5_total -->97<!-- /count -->       |
| Verification           | <!-- count:catalogue_checks -->180<!-- /count --> catalogue checks run from an empty database on every push: <!-- count:assertions -->89<!-- /count --> structural assertions, <!-- count:suites -->104<!-- /count --> adversarial suites |
| Rehearsed on every push | A queue drained in anger, a worker killed mid-dispatch and an endpoint that never answers, an incident declared and communicated, every door named by the application, every screen string renameable, the documents' figures         |
| Languages              | English and a German core pack (<!-- count:de_strings -->558<!-- /count --> strings) with fallback; <!-- count:legislation_packs -->4<!-- /count --> legislation packs with provenance                                                    |

## Running it

```sh
bun install
bun run dev
```

Point it at a Supabase project with `VITE_SUPABASE_URL` and
`VITE_SUPABASE_PUBLISHABLE_KEY` (see `.env.example`).

### The database

```sh
psql -f supabase/ci/00_host_bootstrap.sql
for f in supabase/migrations/*.sql; do psql --single-transaction -f "$f"; done
psql -f supabase/ci/seed_demo.sql          # one organisation with a year of trading
supabase/ci/run_checks.sh                  # every check in the catalogue
```

`supabase/ci/00_host_bootstrap.sql` is everything Clove ERP expects from its
host — the extensions schema, three roles, and `auth.uid()`. Roughly eighty
lines, and the honest answer to "how much of this is locked to Supabase".

### The worker and the status page

```sh
cd worker && bun install && bun run src/main.ts   # claim, do, report
cd infra/status && wrangler deploy                 # the status page, on Cloudflare
```

The worker holds the credentials the database deliberately does not; the
status page holds what the gateway publishes to it. See
[worker/README.md](worker/README.md) and
[supabase/ops/README.md](supabase/ops/README.md) for the operator's runbook:
the live route, the restore drill, releases and rollback, incidents.

## Verifying it

```sh
psql -c "select erp.platform_assurance();"         # the console, as JSON
supabase/ci/run_checks.sh                          # the catalogue, as CI runs it
supabase/ci/drain_rehearsal.sh                     # a queue drained in anger
supabase/ci/recovery_rehearsal.sh                  # a worker killed, an endpoint that hangs
supabase/ci/incident_rehearsal.sh                  # an incident, every channel
supabase/ci/app_doors.sh                           # every door has a home
supabase/ci/screen_strings.sh                      # every screen string has a row
docs/build_counts.sh --check                       # the documents quote the database
```

A check that exists and is not run is a check that is not there:
`erp.ci_check_catalogue()` enumerates every assertion and suite the build can
call, the runner runs them all, and `erp.assert_ci_ran()` refuses if one was
left out.

## Layout

```
supabase/migrations/   the product — a PostgreSQL schema, one file per change, never edited after it ships
supabase/ci/           what it expects from its host, and the rehearsals
supabase/ops/          the operator's runbook
worker/                the dispatch worker (and the Edge Function that shares its core)
infra/status/          the status page
src/                   the application
docs/                  the reference, the specification, and the document built from the build
```
