# Clove ERP

A tenant-neutral, multi-entity ERP platform whose behaviour is configured
rather than coded.

That sentence is the whole design, and it is a claim that has to be paid for.
Paying for it means the configuration engine, the rule engine, the state
machine engine, the approval engine and the promotion machinery all have to
exist _before_ the first module, because a module built before them will be
code — and every module after it will be built to match. The specification says
so explicitly, and orders the work B1 through B10 for that reason.

This document describes what exists. Every figure in it sits inside a marker
that `docs/build_counts.sh` rewrites from the built database and that CI
refuses if it disagrees; the words are a person's, the numbers are not.

---

## 1. What is built

|                        |                                                                                                                                                                                                                                                                              |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Specification**      | <!-- count:spec_version -->v1.6<!-- /count -->, Parts 1–23. Part 5's <!-- count:part5_total -->97<!-- /count --> capabilities: <!-- count:part5_built -->96<!-- /count --> built, <!-- count:part5_partial -->0<!-- /count --> partial, <!-- count:part5_absent -->1<!-- /count --> absent by a recorded decision. |
| **Foundation, B1–B10** | Complete, and every later Part built on it.                                                                                                                                                                                                                                  |
| **Modules**            | <!-- count:modules -->12<!-- /count --> installable modules, each a change set of rules, lifecycles and approval chains promoted through B6 exactly as a customer's own change would be.                                                                                     |
| **Runtime**            | A dispatch worker driving the outbox, the command queue and the scheduler, with a lease, a timeout, and an honest `ambiguous` outcome when the other side never answers.                                                                                                     |
| **Interface**          | An application over a curated API of <!-- count:doors -->543<!-- /count --> doors; a scan-first device client; a platform console; a status page.                                                                                                                             |
| **Build**              | Every migration applied to an empty database on every push, then <!-- count:catalogue_checks -->180<!-- /count --> catalogue checks, three rehearsals against a stub endpoint, and the checks that every door and every screen string has a home.                              |

Concretely: <!-- count:erp_tables -->238<!-- /count --> tenant tables,
<!-- count:ref_tables -->69<!-- /count --> product-content tables,
<!-- count:meta_tables -->63<!-- /count --> platform tables,
<!-- count:enums -->83<!-- /count --> enumerated types,
<!-- count:policies -->345<!-- /count --> row-security policies and
<!-- count:triggers -->770<!-- /count --> triggers — of which the policies and
most of the triggers are _generated_, not written — in
<!-- count:migrations -->269<!-- /count --> migrations and
<!-- count:sql_lines -->177495<!-- /count --> lines of SQL.

### Coverage against the specification

**What of Part 5 is built is a query, not a claim.** `erp_ref.part5_capability`
enumerates every capability Part 5 names, in the specification's own words,
bound to the functions and tables that deliver each one; `erp.assert_part5_coverage()`
fails the build if any artefact named there does not exist, if an absent row has
no decision closing it, or if a closing decision is not accepted. The one absent
capability, customs documentation, is absent by `customs_documentation_not_built`,
which says why a declaration that is nearly right is worse than none. Run
`select * from erp.part5_summary();` for the breakdown by section.

**Every product decision is bound to a check.** `erp_ref.product_decision`
holds D1–D<!-- count:product_decisions -->41<!-- /count --> and
`erp_ref.product_decision_check` binds each to the
<!-- count:product_decision_bindings -->78<!-- /count --> assertions and suites
that enforce it; `erp.assert_product_decisions_enforced()` refuses a decision
with no binding and a binding that names nothing. The
<!-- count:policy_decisions -->35<!-- /count --> policy decisions the build took
along the way are recorded with their evidence, and
<!-- count:policy_decisions_open -->0<!-- /count --> are open.

---

## 2. The idea that makes it work

Every claim the specification makes in prose is a callable function that fails
the build.

Not a convention, not a review checklist, not a comment. `erp.assert_isolation()`
raises. `erp.assert_public_api_safe()` raises. When they raise, the migration
that called them rolls back and the push goes red.

### Generated, never hand-written

Row-level security policies, append-only guards, attribution triggers, audit
coverage, live-configuration guards and execute grants are all _derived_ from
the registers — `erp_meta.table_policy`, `erp_meta.promotable_surface`, the
invoker closure — by `erp.apply_row_security()` and its siblings. Every
migration ends by re-running them, and the build proves a second run changes
nothing.

Hand-written policies are how a table ends up with three of the four it needed.

### Fail safe, not fail open

`erp_meta.register_unregistered_tables()` infers a classification for any table
nobody registered — restrictive by default. Forgetting to register a table gets
you a locked-down table and a failing assertion, not an unprotected one.

### The allow-lists

Where a rule must have exceptions, the exceptions are enumerated with a written
rationale rather than left to judgement, and an assertion refuses an exception
nobody wrote down:

- **`erp_meta.security_definer_allowance`** — <!-- count:definer_allowances -->162<!-- /count --> entries. A `SECURITY DEFINER` function runs as the owner, who bypasses row-level security. Every one in the product schemas is listed with the reason it needs the privilege.
- **`erp_meta.public_write_allowance`** — <!-- count:write_allowances -->393<!-- /count --> entries. The doors permitted to be volatile, each naming the gate it reaches. A volatile `public.erp_*` function that is not listed fails the build; so does one whose gate no longer authorises.
- **`erp_meta.check_run_exemption`** — the catalogue checks CI cannot run without an argument, each naming what drives it instead.
- **`erp_meta.api_only_door`** — <!-- count:api_only_doors -->16<!-- /count --> doors no screen names, each with the caller it exists for (the worker, the build, the device client, an integration, the platform) and <!-- count:doors_pending_screen -->2<!-- /count --> waiting for their screen with the path recorded.
- **`erp_meta.linter_finding_allowance`** — the host's security lints, reimplemented in `erp.linter_report()`, with every remaining finding either fixed or allowed with a reason.

---

## 3. Schemas

| Schema        | Contents                                                                                          | Role                                                                                     |
| ------------- | ------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `erp`         | <!-- count:erp_tables -->238<!-- /count --> tables, <!-- count:erp_views -->15<!-- /count --> views | Tenant data and the engines                                                              |
| `erp_ref`     | <!-- count:ref_tables -->69<!-- /count --> tables                                                 | Product content — what the product knows, identical for every tenant                     |
| `erp_meta`    | <!-- count:meta_tables -->63<!-- /count --> tables                                                | Platform metadata: the registers, the allow-lists, the exemptions, incidents, releases   |
| `erp_ai`      | <!-- count:ai_tables -->2<!-- /count --> tables                                                   | B10. Separate so "never in the transaction path" is checkable                            |
| `erp_ingress` | <!-- count:ingress_functions -->4<!-- /count --> functions                                        | What the website's enquiry function may call, as a role that reaches nothing else        |
| `erp_test`    | <!-- count:suites -->104<!-- /count --> suites                                                    | The harness. Suites build their own organisations, attack them, and roll them back       |
| `public`      | <!-- count:doors -->543<!-- /count --> functions                                                  | The only surface PostgREST exposes                                                       |

Extensions: `pgcrypto`, `pg_jsonschema`, `btree_gist`; `pg_cron` and `pg_net`
where the host has them.

The `erp` schema is **not** exposed to PostgREST. Doing so would put every
table on the REST surface at once; row-level security would still hold, but
_protected by RLS_ and _deliberately exposed_ are different claims and only the
second is a design. `authenticated` reaches `erp.*` only through the invoker
closure of the doors, computed and granted by `erp.refresh_invoker_reach()`;
nothing in the product schemas is executable by `public` or `anon`.

---

## 4. The build sequence

**B1 — Tenancy, identity, row-level security.** Composite `(tenant_id, id)`
foreign keys make a cross-tenant reference unrepresentable rather than
forbidden. Tenant context is a transaction-local GUC, never session-scoped,
because a pooled connection would otherwise carry it to whoever it served next.

**B2 — Audit stream and event store.** Append-only, with payloads validated
against JSON Schema at write time — enforced in SQL as well as by the
extension, because the local build's copy of the extension once said yes to
everything.

**B3 — Configuration and rules.** Effective-dated configuration where an
exclusion constraint over `daterange` guarantees at most one version in force.
Rules are JsonLogic, interpreted by `erp.jsonlogic` — one rule language, reused
everywhere a decision is configurable, from an approval chain to a dimension's
derivation.

**B4 — State machines and approvals.** Lifecycles are configuration. Approval
chains route by JsonLogic over the request context; a step that does not apply
is recorded as `skipped` rather than omitted. A transition's declared effects
are executed, and an effect kind the executor does not know is refused at
promotion.

**B5 — Localisation.** No user-facing literal anywhere: every string resolves
through a resource key and a locale fallback chain with an `en` floor.
<!-- count:en_strings -->2558<!-- /count --> English strings, a German core pack
of <!-- count:de_strings -->558<!-- /count -->, a tenant's own terms under
`custom.`, and a report of what a locale still serves from English.

**B6 — Change promotion.** Configuration in a live environment cannot be edited
directly — it changes by promoting a reviewed change set, or it does not
change. <!-- count:promotable_surfaces -->43<!-- /count --> promotable surfaces,
each guarded; the author of a change set may not approve it.

**B7 — Canonical domain model.** Parties, products, the stock ledger with
deferred-constraint balance checks, an owner and a keeper on every position,
the document spine, finance with a numbered journal and an exact valuation the
ledger agrees with to the penny, planning with a multi-level explosion and a
plan that is kept rather than replaced.

**B8 — Integration.** A transactional outbox with an `xid8` watermark, an
idempotent command gateway whose commands are `queued`, `in_flight`,
`ambiguous` or settled — never re-sent without knowing — and a hard rule that
the database holds credential _references_ and never credentials.

**B9 — Scheduler, notifications, reporting.** The scheduler's dead-man's switch
answers not "did anything fail" but "has each job run as recently as its own
schedule says it should have". <!-- count:job_handlers -->29<!-- /count -->
handlers, run by the database where they can be and by the worker where they
must make a request. Quiet hours _defer_, never suppress. A report has one
version in force; a pack assembles several on a schedule.

**B10 — Configuration intelligence.** Proposes, never applies. Its boundary is
checked by walking the call graph transitively from every registered
transaction-path function.

---

## 5. Above the foundation

**The write surface.** Provisioning creates a tenant, its root company, an
administrator role holding every permission, and the first administrator as an
_invited_ principal with a single-use token. Self-service onboarding creates a
tenant for a caller who has none, inside a bootstrap window that `go_live()`
closes.

**The dispatch worker** (`worker/`). The one component that must live outside
the database, because the database deliberately holds no credentials. Its
vocabulary is claim, do, report — with a lease it must finish inside, a mark
before the wire so a request that was sent is never sent twice, and a pass
record the console reads.

**The modules.** Procurement, sales, inventory, finance, planning, production,
quality, logistics, receivables, master data, reporting and commercial:
<!-- count:modules -->12<!-- /count --> installers, each a change set. A
second organisation, structurally unlike the first — three companies in three
jurisdictions, standard costing, pallet identity, a third-party site, a
consignor, its own words — is onboarded through doors alone by a suite that
reads its own source and refuses any `erp.*` call.

**The platform.** Its own organisation, a price book and quotes, contracts and
renewals; incidents declared with components and scope, communicated on a
timer to every channel from one row, published to the status page through the
gateway, reviewed and closed; <!-- count:platform_dependencies -->5<!-- /count -->
providers polled, an outage below the platform declared and resolved by the
poll; releases recorded and proved; a restore drill that records itself.

---

## 6. Testing

`.github/workflows/schema.yml` stands the product up from nothing on every
push: an empty PostgreSQL, the host bootstrap, then every migration with
`--single-transaction`, then one organisation seeded with a year of trading.

**The catalogue.** `erp.ci_check_catalogue()` reads `pg_proc` and returns every
check the build can call — <!-- count:assertions -->89<!-- /count --> structural
assertions, <!-- count:suites -->104<!-- /count --> adversarial suites, the
whole-database reconciliation last, over every organisation, every posting rule
in force and every bound company. The runner hands the names it ran back to
`erp.assert_ci_ran()`, which refuses if the catalogue holds one it did not run.
A negative step creates an assertion, leaves it out of the list, and proves the
build refuses.

Each suite asserts its own case count, counts a null verdict as a failure, and
rolls its organisation back. A suite that quietly loses a case reports success,
and this repository has lost three isolation cases exactly that way.

**The rehearsals.** Three run against a stub endpoint on every push: a command
and an email drained in anger by the real worker; a worker killed before it
sent, an endpoint that hangs, an endpoint that fails once; an incident declared
and communicated to an organisation in-app and by email, published to the
status page under its key, prompted on its timer, declared and resolved below
the platform by the poll.

**The two directions.** `supabase/ci/app_doors.sh` extracts every `erp_*` name
the application uses: each must exist, and each door the application does not
name must be in `erp_meta.api_only_door` with the caller it exists for.
`supabase/ci/screen_strings.sh` proves every screen string has the row a tenant
renames it by. `docs/build_counts.sh --check` proves this document and the
README quote the database.

**The console.** `erp.platform_assurance()` runs the
<!-- count:diagnostic_checks -->98<!-- /count --> registered diagnostics
(<!-- count:diagnostic_checks_in_ci -->79<!-- /count --> of them also in CI) and
answers green or names what is wrong; every migration ends by requiring it green.

---

## 7. What this found

None of these was found by reading code. Each was found by building from
scratch, by an assertion, or by running the thing.

| Defect                                                                                       | How it surfaced                                       |
| -------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| A view bypassed RLS because a view runs as its owner, who holds BYPASSRLS                    | Adversarial isolation case                            |
| 104 tables were missing tenant-freeze triggers                                               | Generated coverage check                              |
| Session-scoped tenant context was unsafe under connection pooling                            | Commit-boundary test                                  |
| Twelve assertions, including all four reconciliations, existed and were never run            | Building the catalogue runner                         |
| The JSON validator was a `select true` stub on the local build                               | Three gateway cases that passed for the wrong reason  |
| 731 PUBLIC execute grants were load-bearing                                                  | Revoking them                                         |
| No journal ever had a number                                                                 | Reading the eight insert sites                        |
| Average costing rounded to whole pence per receipt; valuation never equalled the ledger      | The costing suite, then a year of trading             |
| Ownership and custody existed nowhere; consignment stock was valued as owned                 | Designing the second organisation                     |
| The allocation policy was configuration nothing read                                         | The same design                                       |
| Nothing scheduled anything; the engine claimed the worker's jobs and failed them every minute | Making the platform run itself                        |
| A dry run could never settle; an expired lease re-sent what had been sent                    | The recovery rehearsal                                |
| A restored copy carried an anon grant on every door                                          | Restoring a dump and running the console              |
| Twenty-three suite wrappers counted a null verdict as a pass                                 | The costing suite's first failure                     |
| A planning run never re-ran, because its own suggestions were supply                         | Writing the scenario comparison                       |
| A door defaulted to a value its table refuses                                                | Giving the door a screen                              |
| Sixty doors were reachable from a SQL client and nowhere else                                | Counting the API against the application              |

### The lesson

**Verify the artefact, not the green tick.** More than once a change merged
that reported success and did nothing. Each time the tick was read and the log
was not. The rehearsals, the catalogue runner and the two-direction door check
exist so the tick and the artefact are the same thing.

---

## 8. What is still not proven

Stated plainly, because the register would be worth nothing otherwise.

- **Point-in-time recovery has never been drilled.** The dump-and-restore
  drill runs quarterly and records itself; a PITR is performed on the host and
  is recorded by the operator through `erp_platform_record_restore_drill('pitr', …)`
  once done.
- **The status page is under Cloudflare's own availability.** It stores what
  the gateway publishes and serves it; a page served from the product's
  database would die with it, which is the decision recorded as
  `status_page_published_through_the_gateway`.
- **German beyond the core pack** is served from English and reported as such
  by `erp_untranslated('de')`; a tenant's own words stay untranslated in every
  other locale by design.
- **Customs documentation is not built** (`customs_documentation_not_built`).
- **Consolidation does not translate currencies**: a member in another
  currency is refused, not summed. Settlement fees are recorded on the
  statement, not posted.
- **The live route depends on a secret** (`CLOVEERP_LIVE_DATABASE_URL`) and on
  the branching integration's production deploy; both are the owner's, and
  `supabase/ops/README.md` says what each carries.

---

## 9. Running it

```sh
# The application
bun install && bun run dev

# The full build, exactly as CI runs it
psql -f supabase/ci/00_host_bootstrap.sql
for f in supabase/migrations/*.sql; do psql --single-transaction -f "$f"; done
psql -f supabase/ci/seed_demo.sql
supabase/ci/run_checks.sh

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

It builds the same tenant the operator door does, with one difference: the
environment is not yet live. That is the **bootstrap window**. Inside it, an
installer approves and promotes in the same call, because separation of duties
has nobody to separate from. `erp.go_live()` closes it, and refuses to close it
over dead configuration or over a tenant with a single administrator. After
that a self-service tenant is governed exactly as a provisioned one is.
