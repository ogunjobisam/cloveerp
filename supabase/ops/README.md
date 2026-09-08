# Operations

One-off scripts that repair a specific database. Nothing here is part of the
product's definition, and nothing here runs in CI.

The distinction matters. `supabase/migrations/` is the sequence that builds
Clove ERP from nothing, and CI proves on every push that it still does. A script
in this directory is the opposite: it exists because one particular database
drifted from that sequence, and it is written against the state that database
actually reached rather than the state the repository describes.

A file here has done its job once it has been applied. It is kept because the
repair should be reviewable and reproducible, not because it will be needed
again.

**The refusal codes in these files are the retired ones.** 20260904980000 moved
every refusal from `ERPWARE_` to `CLOVEERP_`; these scripts are dated records of
what was actually run on a given day and have not been rewritten, because a
record that has been edited to look current is no longer a record. Do not copy a
raise out of one. Replaying a script from here would put the old prefix back into
the routines it touches, and `erp.assert_no_legacy_refusal_prefix()` would fail
the next build — which is the guard working, not a false alarm.

---

## How live is reached from 6 September 2026

Nothing in this directory is the route to production any more. Two workflows
are:

- `.github/workflows/deploy.yml` — on every push to `main`, applies the
  repository's pending migrations to the live project by replay
  (`supabase db push --include-all`), then runs `erp.platform_assurance()` and
  `erp.assert_whole_database_reconciles()` over the same connection and fails
  if either is not green. On every pull request it prints what would apply.
- `.github/workflows/restore_drill.yml` — quarterly and on demand, dumps the
  product schemas from live, restores them into a fresh PostgreSQL of the
  live major version on the runner, and runs the same two checks against the
  restored data. D28.

Both read one repository secret, `CLOVEERP_LIVE_DATABASE_URL`: the project's
session-pooler connection string (the direct host is IPv6-only and a runner
cannot reach it), percent-encoded. It is set by the project owner and read by
nobody else; no connection string is stored anywhere in this repository or in
the environment the work is done from, and none should be.

**Before the first replay**, the live history table has to learn which
repository migrations it already carries: every change up to and including
`20260905040000` reached live through the Supabase MCP connector, which
recorded its own names rather than the repository's filenames. Run `deploy`
by hand once with `mark_applied = true` and `mark_applied_through` set to the
highest version already on live — `20260905040000`. The stamps naming no
repository file are reverted, everything at or below the boundary is recorded
as applied, and replay starts from the one after it. Running it twice is
harmless; running it without the boundary would record every later migration as
applied without applying it, which is the one way to misuse it, so the workflow
refuses without one.

**This was done on 8 September 2026**: 160 connector-era stamps reverted, 242
recorded as applied. The replay that followed applied 14 more
(`20260906010000` through `20260906111000`) and then stopped, and the two
things it ran into are worth knowing before the next one.

*A deadlock.* Every migration ends by re-running the generators, and
`erp.apply_row_security()` and `erp.apply_execute_grants()` take heavy locks
across hundreds of objects; the `cron.job` that fires every minute crossed with
them twenty-eight minutes in. `deploy.yml` now retries three times on `40P01`
and resumes from the migration that lost, so this costs a delay rather than a
deploy. Consider pausing `cron.job` for a long replay anyway.

*The text-surgery wall.* Seventeen of the remaining migrations rewrite an
existing function by reading `pg_get_functiondef()` and requiring exact
substrings. The connector left bodies that are functionally equivalent and
textually different, so those guards refuse — correctly. Twelve functions are
affected, all in the write gateway and the worker.
`20260908_gateway_function_bodies.sh` builds the repository from empty to
live's own high-water mark, compares the twelve, and re-emits the reference
body for any that differ. Run it report-only first. Once it reports no
differences, dispatch `deploy` with `mark_applied` unset and the replay
continues.

The connector remains available for reading and for an emergency; it is no
longer how a change lands.

## Releases and rollback

A release is a row. `deploy.yml` writes one to `erp_meta.release` after the
migrations apply and before the database is proved: the commit, the moment the
deploy started, the migration ledger as it stood, and — once
`erp.platform_assurance()` and `erp.assert_whole_database_reconciles()` pass —
`proved_at`. `erp.release_report()` reads the register beside the ledger, the
platform console's deployment screen shows the last five, and a ledger that has
moved past the last recorded release is a finding of
`erp.assert_release_integrity()`: a migration that reached live without a
deploy is what the release route exists to prevent (D27).

Three things can be rolled back, and they roll back differently.

- **The schema does not roll back; it rolls forward.** No down migration is
  written (D27); a migration that must be undone is undone by the next
  migration, which says why. `supabase/ci/migrations_immutable.sh` refuses an
  edited file, so history stays what was applied.
- **The application rolls back by publishing the previous build** in Lovable.
  That is safe only when the previous build's doors still exist on the current
  schema, which the `compat` job in `schema.yml` proves on every pull request:
  it builds the schema as `main` has it and as the pull request leaves it,
  extracts every door name the application calls on each side, and fails the
  request if `main`'s application calls a door the request removes. A door
  that must go is kept as a shim for one release first.
- **Data rolls back by point-in-time recovery** to `deployed_at_start` of the
  release being undone — the `pitr` commitment — and a restore is only a hope
  until it has been drilled. `restore_drill.yml` drills it quarterly: dump,
  restore into an isolated PostgreSQL of the live major version, run the
  console and the reconciliation, then keep one organisation and run them
  again. Since 6 September 2026 the drill records itself through
  `erp.record_restore_drill()`, so `erp.continuity_report()` reads `proved`
  from a row a drill wrote rather than `never drilled` from a table nothing
  could write to. A drill done by hand is recorded through
  `erp_platform_record_restore_drill` by the operator who did it.

A rehearsal of the application rollback on live — publish the previous build,
walk the routes, republish — is the owner's to perform; the `compat` job says
beforehand whether it can succeed, and this file is where its date is recorded
when it has been done.

## Incidents and the status page

Specification v1.6 §16.5. An incident update is one row
(`erp_meta.incident_update`) and every channel carries it unchanged:

- **The application.** The shell shows a banner to every organisation the
  incident reached, from the same `erp_service_notices()` the continuity
  screen reads, once a minute. An incident declared as reaching everyone is
  shown from the moment it is declared, not only once containment repeats it.
- **Email and the in-app notice.** The platform sweep
  (`erp.run_due_jobs_all_tenants()`, every minute where `pg_cron` runs)
  delivers each declaration and update to each organisation reached through
  `erp.communicate_incidents()`: one in-app row and one queued email per
  recipient — the organisation's administrators by default, anyone who
  subscribed on the continuity screen, minus anyone who stepped out.
  `erp_meta.incident_delivery` is the record; the console shows it.
- **The status page.** In the platform's own organisation, the same sweep
  publishes each declaration and update as a `status.publish` command to every
  active external system on adapter `status_page@1`, and the dispatch worker
  delivers it with an idempotency key. `infra/status/` is the page: a
  Cloudflare Worker with one KV namespace that stores what it is sent. The
  decision `status_page_published_through_the_gateway` supersedes
  `status_page_not_built`; the page is still outside this database.
- **The timer.** `erp_meta.incident.next_update_due_at` is set at declaration
  and on every update, from the severity's cadence or an earlier promise. The
  sweep's `erp.prompt_incident_updates()` records a prompt to the
  communications owner when it passes, escalates to the commander after the
  severity's response window and to the owner role after two, writes the
  audit row each time, and tells the named person in the platform organisation
  when their email is a person there. `erp.support_discipline_report()` fails a
  live incident past its promise and an update ten minutes past due with no
  prompt — the second is how a sweep that stopped shows up.
- **Providers below the platform.** `erp_ref.platform_dependency` lists
  Supabase, Resend, Cloudflare, Lovable and GitHub with their Statuspage v2
  feeds. The worker handler `platform.poll_dependency_status` reads them; a
  major or critical indicator declares a severity-3 incident with the origin,
  the components the provider carries and the scope the row states; recovery
  posts the closing update and resolves it.
- **History and the review.** `erp_incident_history()` shows an organisation
  every incident that reached it, for as long as the register holds it (D36).
  `erp.assemble_incident_review()` builds the blameless review from the
  updates, the prompts, the organisations reached and the actions;
  `erp_meta.incident_action` tracks the actions, and the open actions of
  incidents sharing a component are shown when a new one is declared.

### Owner actions, once, on live

1. Designate the platform's own organisation (`erp_platform_designate_organisation`
   from the console, or `erp.designate_platform_organisation(code, reason)`),
   if not already done for the commercial process.
2. Deploy `infra/status/` (`wrangler kv namespace create STATUS`,
   `wrangler secret put STATUS_PUBLISH_TOKEN`, `wrangler deploy`) and point
   `status.<domain>` at it. The token is never stored in the product.
3. In the platform organisation, register an external system on adapter
   `status_page@1` with `connection = {"base_url": "https://<host>/publish"}`
   and `credential_ref = env://CLOVEERP_STATUS_TOKEN`; enable the operation
   `status.publish`; give the dispatch worker `CLOVEERP_STATUS_TOKEN` and add
   the system's code to `CLOVEERP_SYSTEMS`.
4. In the platform organisation, create the job `poll_dependency_status` on
   handler `platform.poll_dependency_status` (interval, five minutes is
   plenty). It needs the worker: the database engine leaves it alone and
   reports it as left for the worker.
5. Declare a severity-4 test incident scoped to the demonstration organisation,
   post one five-field update, and read the console's Communication panel, the
   organisation's banner, the email, and the status page. Record the date here.

The build rehearses the whole path on every push
(`supabase/ci/incident_rehearsal.sh`): declaration, update, delivery, the
worker's publication to a stub status page, the timer's prompt, a provider
feed going dark and recovering, the review, the resolution and the history.

### The application: how it is published

The schema and the application are deployed by different routes, and only the
schema's is a workflow. The application is built and published **by hand from
the Lovable editor**, which produces a Cloudflare Worker (`ogunjobisam-erpware`
in the generated `.output/server/wrangler.json`) serving `cloveerp.com`.
Nothing in this repository publishes it; `deploy.yml` records the release and
names the channel `lovable`, which is the only trace of it here.

The consequence that has bitten once: every `VITE_*` value is **inlined into
the bundle at build time**, so there is no runtime configuration to change
afterwards — a wrong or missing value is fixed by a re-publish and by nothing
else. On 6 September the published site served "Not connected to a project" to
every visitor, because the two values the browser needs had only ever lived in
a tracked `.env` and that file left version control on 5 September. They are
now defaulted in `src/lib/erp.ts`, so a build with no environment at all still
reaches the project, and `schema.yml` reads the built bundle to prove it.

To point the application at a different project, set `VITE_SUPABASE_URL` and
`VITE_SUPABASE_PUBLISHABLE_KEY` in Lovable's Supabase connection (the `VITE_`
names cannot be set through its secrets tool, which reserves them) and publish
again. To rotate the publishable key of *this* project, change the constant in
`src/lib/erp.ts` and publish: the key is public by definition — it is in every
bundle already, `anon` holds EXECUTE on nothing, and every table is behind row
security — so it belongs where the build can always find it.

### Settings that live only in the dashboard

Two authentication settings cannot be expressed in `supabase/config.toml` and
are therefore recorded here, with the date, when they are changed:

| Setting | State | Changed | By |
|---|---|---|---|
| Leaked-password protection (HaveIBeenPwned check on new passwords) | to be switched on — Phase 2 asks for it | — | — |
| Publishable (anon) key rotation after `.env` left version control | to be rotated — Phase 2 asks for it. Rotating it now means the new key in `src/lib/erp.ts` and a re-publish, because the browser's copy is inlined at build time | — | — |

Update the row when the change is made. A row that says "to be" for long is
itself a finding.

---

## 20260831_live_reconciliation.sql

Brings the production project (`xpzffnnhnhcqyjqcueja`) to the schema `main`
describes.

### Why a script rather than the migrations

Production has 139 migrations applied, newest `20260830134027`. It has every
migration the Lovable integration wrote and none of the eight written in the
session that produced pull requests #20 to #22. Five of those eight are
numbered *earlier* than work already applied there, so the repository's filename
order and production's history disagree.

Replaying the eight in filename order was tried against a local copy of
production's state. All eight fail and none applies:

```
20260829330000  ERPWARE_PUBLIC_API_UNSAFE: 112 finding(s)
20260829340000  ERPWARE_PUBLIC_API_UNSAFE: 114 finding(s)
20260829350000  ERPWARE_PUBLIC_API_UNSAFE: 112 finding(s)
20260829360000  column bt.create_permission does not exist
20260829370000  ERPWARE_PUBLIC_API_UNSAFE: 112 finding(s)
20260830140000  function erp.create_party(...) does not exist
20260830150000  function public.erp_create_party_with_roles(...) does not exist
20260831130000  column bt.create_permission does not exist
```

The cause is structural rather than accidental. Each of the August 29
migrations ends by calling `erp.assert_public_api_safe()`, which on that
database is still the blanket ban on public `SECURITY DEFINER`; the
platform-owner layer added later violates it 27 times. The migration that turns
that ban into a registered one is `20260830140000`, which sorts *after* them and
then fails itself because the migration it depends on has rolled back. Every
migration is atomic, so each failure leaves nothing behind and the next fails on
the gap.

So the script is generated from the target instead. Every routine body in it
came from `pg_get_functiondef()` against a build of `main` from empty; nothing
was retyped. Its order is dependency order rather than filename order.

### What it changes

| | |
|---|---|
| Routines defined or replaced | 32 |
| Routines dropped | 2 |
| Columns added | 2 |
| Triggers emitted by the generators | 34 |
| Write-register rows | 206 asserted |
| `SECURITY DEFINER` register rows | 55 asserted |
| English strings | 22 added |

The largest correction has nothing to do with the eight migrations. Twenty-one
tables are registered in `erp_meta.table_policy` and never had their triggers
emitted, because nothing re-ran the generators after they were created: 18
audit, 8 tenant-freeze, 6 attribution and 2 append-only guards. Until this runs,
changes to those tables do not reach the audit stream, a row can be moved to
another tenant by `UPDATE`, and `approval_routing_stamp` and
`item_code_assignment` can be edited or deleted despite being append-only.

### How it is verified

CI cannot verify this file. CI builds from empty and applies the migration
sequence, on which the script is a no-op by design — so CI proves it does no
harm and never that it does the job.

`20260831_equivalence_check.sh` is the part that proves it does the job. It
builds the repository twice, once without the eight migrations and once whole,
applies the script to the first, and compares the two on ten dimensions:
routines (identity, body digest, `SET` clause, kind, definer, volatility),
columns, triggers, policies, both registers, base-type permissions, English
resources, the Part 5 register, and the execute grants on the public API.

It also applies the script a second time, and applies it to a database that
already carries `main`, because a repair that is not idempotent and not a no-op
on the finished article is a repair nobody can run twice.

```
./supabase/ops/20260831_equivalence_check.sh
```

Last run: identical on all ten dimensions — 779 routines, 3,297 columns, 593
triggers, 240 policies, 206 write-register rows, 55 definer rows, 13 base types,
688 English strings, 90 Part 5 capabilities, 285 grants.

### Applying it

Against the project directly, in one transaction, having read it first. It ends
with all 22 structural assertions, so a database it would leave in a state the
product considers wrong rolls the whole thing back instead.

It does not install any module. Installing sales, procurement and master data on
production is a separate decision and a separate change, and it should follow
this rather than precede it: installing onto a schema that does not match the
repository is how the divergence widened in the first place.

### Applied — 31 August 2026

Applied to `xpzffnnhnhcqyjqcueja` in thirteen migrations named `reconcile_*`,
because the only channel available was the Supabase MCP tool rather than a
`psql` connection: the project has no stored database password anywhere in the
repository or environment, and the egress proxy refuses both `api.supabase.com`
and the project host. Each part was verified against a local build of `main`
before the next was applied.

Twelve of the thirteen dimensions below now match that build **exactly**:

| | on `main` | on production |
|---|---|---|
| `erp_ref` / `erp_meta` / `erp_ai` / `erp_test` / `public` routines | — | identical |
| triggers in the `erp*` schemas | 593 | 593, identical |
| policies | 240 | 240, identical |
| write register | 206 | 206, identical |
| `SECURITY DEFINER` register | 55 | 55, identical |
| base-type permissions | 13 | 13, identical |
| English resources | 688 | 688, identical |
| Part 5 register | 90 | 90, identical |
| `erp` routines | 440 | 440, **8 differ** — see below |

All 22 assertions pass on production. Two of them failed on the first attempt
and both failures were real:

- `assert_isolation()` — six `erp` functions were `SECURITY DEFINER` with no
  register row. Fixed by the six rows the script carries.
- `assert_transaction_control_routines()` — `erp_test.assert_context_not_leaked`
  still carried the `SET search_path` a linter had added, which PostgreSQL
  refuses to let a procedure commit under. This is the guard written for
  exactly that defect catching it in production, on its first run there.

The generator step did what it was written to do: 559 → 593 triggers, and the
audit and attribution coverage reports went from 20 and 14 findings to none.

### Two things this exercise found that the script does not fix

**Production's function bodies have had their comments stripped.** Every
`--` comment is gone from every routine on that database, so `md5(prosrc)`
differs from `main` for essentially all 779 of them while the code is
identical. This is why the verification above compares bodies with comments
removed and whitespace collapsed; a raw comparison reports hundreds of
differences that are not differences. It also means production can never be
made byte-identical to `main` without rewriting every function, which would
be a large change of no behavioural value. Nothing reads a comment: the gate
detection in `erp.public_api_report()` matches on call text, not commentary.

**Eight `erp` routines differ beyond comments, and all eight are inert.**
They were checked one at a time rather than assumed:

| routine | difference |
|---|---|
| `perform_transition` | `main` declares `v_effects jsonb`, never used |
| `open_approval_seq` | `main` initialises `v_made := 0`, always assigned before use |
| `audit_coverage_report` | one string literal on production, two adjacent ones on `main` |
| `decide_approval_task` | production parenthesises the `CASE` before the cast |
| `evaluate_legislation_rules` | `main` selects `b.pack_version`, never referenced |
| `run_legislation_conformance` | the same unused selected column |
| `submit_command` | `main` declares `v_req` in an inner block, production in the outer one |
| `request_approval` | the two supersede/cancel `UPDATE`s run in the opposite order, over the same set |

No gate, guard, permission check or tenant scope differs in any of them. They
were left alone during the repair itself: rewriting the state machine, the
approval router and the integration gateway by hand-typing them through a tool
channel would have been risk without benefit.

`20260901_eight_inert_routines.sql` is the reviewed change that closes them,
for a database reachable by `psql`. It fixes no defect — it exists so that a
body-level comparison between production and `main` comes back clean, which is
what makes the *next* drift visible. Running it is optional and the file says
so.

Note also that the earlier claim that production matched "repository minus the
eight migrations" was established on counts and presence, not on body content.
It held for the shape and not for the text, which is how these eight went
unnoticed until the digests were compared.
