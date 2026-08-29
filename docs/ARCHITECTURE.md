# ERPWare

A tenant-neutral, multi-entity ERP platform whose behaviour is configured
rather than coded.

That sentence is the whole design, and it is a claim that has to be paid for.
Paying for it means the configuration engine, the rule engine, the state
machine engine, the approval engine and the promotion machinery all have to
exist _before_ the first module, because a module built before them will be
code — and every module after it will be built to match. The specification says
so explicitly, and orders the work B1 through B10 for that reason.

This document describes what exists.

---

## 1. What is built

|                        |                                                                                                                 |
| ---------------------- | --------------------------------------------------------------------------------------------------------------- |
| **Foundation, B1–B10** | Complete. 49 migrations, ~25,100 lines of SQL.                                                                  |
| **First module**       | Procurement: requisition → purchase order → goods receipt.                                                      |
| **Runtime**            | A dispatch worker driving the outbox, the command queue and the scheduler.                                      |
| **Interface**          | An app shell over a curated read/write API.                                                                     |
| **Build**              | Every migration applied to an empty database on every push, then eleven assertions and four adversarial suites. |

Concretely: 159 tables, 248 functions, 66 enumerated types, 166 row-security
policies and 417 triggers — of which the policies and most of the triggers are
_generated_, not written.

### Coverage against the specification

Sections cited in migration headers, which is where the mapping is authoritative:

| Part                 | Sections implemented                 |
| -------------------- | ------------------------------------ |
| 2 — Tenancy          | 2.1 – 2.5                            |
| 3 — Platform engines | 3.1 – 3.12                           |
| 4 — Canonical model  | 4.1 – 4.10                           |
| 5 — Modules          | 5.1 – 5.11, all eleven areas         |
| 6 — Extensibility    | 6.1, 6.3                             |
| 7 — Prohibitions     | enforced throughout                  |
| 8 — Invariants       | enforced throughout                  |

**What of Part 5 is built is a query, not a claim.** `erp.part5_coverage()`
enumerates all ninety capabilities Part 5 names, in the specification's own
words, bound to the functions and tables that deliver each one — and
`erp.assert_part5_coverage()` fails the build if any artefact named there does
not exist. At the last build: **73 built, 16 partial, 1 absent.**

Every partial and the one absent capability carries a written gap saying
exactly what is missing. Marking them built would have been easy and would have
made every other row untrustworthy. Run `select * from erp.part5_summary();`
for the breakdown by section.

---

## 2. The idea that makes it work

Every claim the specification makes in prose is a callable function that fails
the build.

Not a convention, not a review checklist, not a comment. `erp.assert_isolation()`
raises. `erp.assert_public_api_safe()` raises. When they raise, the migration
that called them rolls back and the push goes red.

That single decision is why the defects listed in §7 were found at all. None of
them was found by reading code.

### Generated, never hand-written

Row-level security policies, append-only guards, attribution triggers and audit
coverage are all _derived_ from one registry, `erp_meta.table_policy`, by
`erp.apply_row_security()` and its siblings. Every migration ends by re-running
them, and CI proves a second run changes nothing (166 policies and 417 triggers
before and after).

Hand-written policies are how a table ends up with three of the four it needed.

### Fail safe, not fail open

`erp_meta.register_unregistered_tables()` infers a classification for any table
nobody registered — restrictive by default. Forgetting to register a table gets
you a locked-down table and a failing assertion, not an unprotected one.

### The two allow-lists

Where a rule must have exceptions, the exceptions are enumerated with a written
rationale rather than left to judgement:

- **`erp_meta.security_definer_allowance`** — 5 entries. A `SECURITY DEFINER`
  function runs as the owner, who bypasses row-level security. Every one in the
  product schemas is listed here with the reason it needs the privilege; an
  unlisted one fails the build.
- **`erp_meta.public_write_allowance`** — 18 entries. The API functions
  permitted to write, each naming the gate it reaches. A volatile
  `public.erp_*` function that is not listed fails the build; so does one whose
  gate no longer authorises.

---

## 3. Schemas

| Schema     | Contents            | Role                                                                 |
| ---------- | ------------------- | -------------------------------------------------------------------- |
| `erp`      | 129 tables, 8 views | Tenant data and the engines                                          |
| `erp_ref`  | 19 tables           | Product content — what the product knows, identical for every tenant |
| `erp_meta` | 9 tables            | Platform metadata: the registry, the allow-lists, the exemptions     |
| `erp_ai`   | 2 tables            | B10. Separate so "never in the transaction path" is checkable        |
| `erp_test` | 0 tables            | The harness. Suites build their own tenants and destroy them         |
| `public`   | 28 functions        | The only surface PostgREST exposes                                   |

Extensions: `pgcrypto`, `pg_jsonschema`, `btree_gist`.

The `erp` schema is **not** exposed to PostgREST. Doing so would put ~130 tables
on the REST surface at once; row-level security would still hold, but
_protected by RLS_ and _deliberately exposed_ are different claims and only the
second is a design.

---

## 4. The build sequence

**B1 — Tenancy, identity, row-level security.** Composite `(tenant_id, id)`
foreign keys make a cross-tenant reference unrepresentable rather than
forbidden. Tenant context is a transaction-local GUC, never session-scoped,
because a pooled connection would otherwise carry it to whoever it served next.

**B2 — Audit stream and event store.** Append-only, with payloads validated
against JSON Schema at write time.

**B3 — Configuration and rules.** Effective-dated configuration where an
exclusion constraint over `daterange` guarantees at most one version in force.
Rules are JsonLogic, interpreted by `erp.jsonlogic` — one rule language, reused
everywhere a decision is configurable.

**B4 — State machines and approvals.** Lifecycles are configuration. Approval
chains route by JsonLogic over the request context; a step that does not apply
is recorded as `skipped` rather than omitted, so the audit shows it was
considered.

**B5 — Localisation.** No user-facing literal anywhere: every string resolves
through a resource key and a locale fallback chain.

**B6 — Change promotion.** Configuration in a live environment cannot be edited
directly — it changes by promoting a reviewed change set, or it does not
change. The author of a change set may not approve it.

**B7 — Canonical domain model.** Parties, products, the stock ledger with
deferred-constraint balance checks, the document spine, finance, planning. One
spine carries all thirteen document types of spec 4.5.

**B8 — Integration.** A transactional outbox with an `xid8` watermark, an
idempotent command gateway, and a hard rule that the database holds credential
_references_ and never credentials — enforced by `erp_ref.looks_like_secret()`.

**B9 — Scheduler, notifications, reporting.** The scheduler's dead-man's switch
(`erp.silent_jobs()`) answers the question a dashboard of failures cannot: not
"did anything fail" but "has each job run as recently as its own schedule says
it should have". Quiet hours _defer_, never suppress. A KPI has exactly one
calculation in force at a time, by exclusion constraint.

**B10 — Configuration intelligence.** Proposes, never applies. Its boundary is
checked by walking the call graph transitively from every registered
transaction-path function: a one-hop check would be defeated by a single helper.

---

## 5. Above the foundation

**The write surface.** Provisioning creates a tenant, its root entity, an
administrator role holding every permission, and the first administrator as an
_invited_ principal with a single-use token. Self-service onboarding creates a
tenant for a caller who has none. Both routes exist because they answer
different questions.

**The dispatch worker** (`worker/`, ~520 lines). The one component that must
live outside the database, because the database deliberately holds no
credentials. Its entire vocabulary is claim, do, report. The database decides
what is due, what may overlap, what a failure costs and when the next attempt
happens — so a bug in the worker cannot corrupt a schedule.

**Procurement** — the module that proves the thesis. No new tables. Three state
machines, a value-banded approval chain, numbering rules and document types,
promoted through B6 exactly as a customer's own change would be.

---

## 6. Testing

`.github/workflows/schema.yml` stands the product up from nothing on every
push: an empty PostgreSQL 17.6, the host bootstrap (~80 lines — the entire
Supabase surface), then every migration with `--single-transaction`.

**Eleven structural assertions** read the catalogue and need no fixtures.
**Four adversarial suites** — 81 cases — build their own tenants, attack them,
and destroy them.

Each suite asserts its own case count. That is not ceremony: a suite that
quietly loses a case reports success, and this repository has lost three
isolation cases exactly that way.

Two things the workflow checks that applying migrations to a long-lived
database structurally cannot: that the sequence still applies to an _empty_
cluster, and that the generators are idempotent.

---

## 7. What this found

None of these was found by reading code. Each was found by building from
scratch, or by an assertion, or by running the thing.

| Defect                                                                    | How it surfaced                            |
| ------------------------------------------------------------------------- | ------------------------------------------ |
| A view bypassed RLS because a view runs as its owner, who holds BYPASSRLS | Adversarial isolation case                 |
| A `SECURITY DEFINER` frame allowed privilege escalation                   | Definer allow-list                         |
| 104 tables were missing tenant-freeze triggers                            | Generated coverage check                   |
| Service principals were unreachable — nothing could create one            | Building B8's worker contract              |
| Session-scoped tenant context was unsafe under connection pooling         | Commit-boundary test                       |
| Three isolation cases had silently vanished from the repository           | Building CI from scratch                   |
| Two CI "fixes" merged while changing nothing at all                       | Reading the artefact, not the tick         |
| A purchase order silently ran the _requisition's_ lifecycle               | Driving procurement end to end             |
| Six `SECURITY DEFINER` functions on the public API                        | Assertions, after a parallel branch merged |
| A seed with hard-coded UUIDs failed the build on an empty database        | CI going red                               |
| Self-service tenants were never governed, permanently                     | Asking whether the product was too strict  |
| A solo administrator could install no configuration at all                | The same question, from the other side     |
| The two tenant-creation doors built two different tenants                 | Trying to configure one of them            |
| 58 operations were reachable from nowhere                                 | Counting the public API against `erp.*`    |
| A test suite left its tenant behind, so it could only run once            | Re-reading my own merged code              |

The last three of the merge batch arrived when a second line of work merged.
The assertions caught all of them within minutes.

The four after that came from a question rather than a test — "is the app
restrictive about writing to the database and creating tenants?" — and the
answer turned out to be both yes and no at once, which is the shape of most of
this section. `erp.guard_live_configuration()` reads the environment marked
`is_self` to decide whether a tenant is still being built. The self-service door
created no such row, so the guard's `coalesce(is_live, false)` answered "still
being built" for ever: those tenants were not governed leniently, they were
never governed. Meanwhile B6's refusal to let the author of a change set approve
it — correct, and the reason the guard exists — meant a person on their own
could not install a single module, because there was nobody else to approve it.
Too loose and too tight, from the same missing row.

The last one is mine, found after the change above had merged green. Fifteen of
the sixteen adversarial suites end with the same three lines — open a purge
window, delete the tenant, close it — and the sixteenth, which I had just
written, ended by clearing the session claims and stopping. CI could not see it:
the database is created empty, the suite is the only thing that has ever run,
and the cluster is thrown away a minute later. Two local databases could see it
immediately — both carried a leftover tenant, and both refused the suite on its
second run, failing on a unique tenant code rather than on anything under test.
The suite also fabricates rows in `auth.users`, which is the platform's identity
table rather than the product's and has no foreign key to cascade along, so
those survived too. **The green tick again described the run, not the artefact.**

### The lesson

**Verify the artefact, not the green tick.** Twice in this build a change was
merged that reported success and did nothing. Both times the tick was read and
the log was not.

---

## 8. Known gaps

- **`transition.effects` and `state.on_enter`/`on_exit` are never executed.**
  Stored configuration that nothing reads. `erp.assert_no_dead_configuration()`
  now fails the build if any is declared, so the gap is loud rather than silent
  — but executing effects is real work still outstanding.
- **Two migration naming conventions.** Hand-numbered `00NN` files and
  timestamped ones. _Every_ `00NN` file sorts before _every_ timestamped file,
  so anything correcting a timestamped migration must itself be timestamped
  later. A fix numbered `0045` was silently undone by files that ran after it.
- **`.env` is committed** and there is no `.gitignore` rule for it. Today it
  holds only publishable values; that is where a `service_role` key eventually
  lands.
- **Local development on PostgreSQL 16** runs `pg_jsonschema` 0.3.3, which does
  not enforce `required`. Three gateway cases fail locally and pass on CI's
  17.6 image.

---

## 9. Running it

```sh
# The application
bun install && bun run dev

# The full build, exactly as CI runs it
psql -f supabase/ci/00_host_bootstrap.sql
for f in supabase/migrations/*.sql; do psql --single-transaction -f "$f"; done

# The worker
cd worker && bun install && bun run src/main.ts
```

**Provisioning a tenant** is an operator action — no principal exists yet to
authorise it, so it is gated on a database role that bypasses RLS and is
deliberately absent from the public API:

```sql
select * from erp.provision_tenant('acme', 'Acme Ltd',
                                   'admin@acme.example', 'Acme Admin');
```

It returns a single-use token. The administrator signs in and redeems it; from
then on everything goes through the gated API.

**Creating a tenant for yourself** is the other door, and it is on the public
API, because a signed-in caller with no principal is the one case where there is
nothing to authorise against:

```sql
select public.erp_onboard_tenant('Acme Ltd', 'acme');
```

It builds the same tenant the operator door does — root entity, administrator
role, `is_self` environment — with one difference: the environment is not yet
live. That is the **bootstrap window**. Inside it, `erp.install_module_config()`
approves and promotes in the same call, because separation of duties has nobody
to separate from. `erp.go_live()` closes it, and refuses to close it over dead
configuration or over a tenant with a single administrator — either would leave
a tenant that is governed and unable to change. After that a self-service tenant
is governed exactly as a provisioned one is: configuration moves through a
promoted change set, and an author may not approve their own.
