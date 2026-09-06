# Clove ERP — What has been built

This document is generated from the build. Every figure in it is read from the database the build produces, by `docs/build_counts.sh`; the document is rebuilt and compared on every push, so it cannot describe a build that no longer exists. Specification {spec_version}.

## 1. In one paragraph

Clove ERP is a tenant-neutral, multi-entity ERP platform whose behaviour is configured rather than coded. The product is a PostgreSQL schema of {migrations} migrations and {sql_lines} lines of SQL, exposing {doors} public functions — the doors — to an application, a device client, a dispatch worker and a platform console. Every rule the specification states in prose is a function that fails the build; every capability Part 5 names is a row in a register that says what delivers it; every decision the design took is bound to the check that enforces it; every door either has a screen or a row saying who calls it instead.

## 2. The figures

| What | How many | Where it is counted |
| --- | --- | --- |
| Migrations | {migrations} | `supabase/migrations/`, one file per change, never edited after it ships |
| Tenant tables | {erp_tables} | schema `erp`, with {erp_views} views |
| Product-content tables | {ref_tables} | schema `erp_ref`: what the product knows, identical for every organisation |
| Platform tables | {meta_tables} | schema `erp_meta`: registers, allow-lists, incidents, releases |
| Public doors | {doors} | schema `public`; {doors_writing} may write, each with a registered gate |
| Doors with no screen | {api_only_doors} | `erp_meta.api_only_door`, each with its caller; {doors_pending_screen} waiting for a screen |
| Structural assertions | {assertions} | `erp.assert_*`, read the catalogue, need no fixtures |
| Adversarial suites | {suites} | `erp_test.*_suite`, each pinned to its case count |
| Catalogue checks run on every push | {catalogue_checks} | `erp.ci_check_catalogue()`, and `erp.assert_ci_ran()` refuses one left out |
| Console diagnostics | {diagnostic_checks} | `erp_meta.diagnostic_check`; {diagnostic_checks_in_ci} also in CI |
| Row-security policies | {policies} | generated from the table register |
| Triggers | {triggers} | generated, mostly |
| Enumerated types | {enums} | |
| Modules | {modules} | each an installer that authors a change set |
| Legislation packs | {legislation_packs} | with provenance on every value |
| Product decisions | {product_decisions} | D1–D{product_decisions}, bound by {product_decision_bindings} checks |
| Policy decisions | {policy_decisions} | taken during the build, with evidence; {policy_decisions_open} open |
| Part 5 capabilities | {part5_total} | {part5_built} built, {part5_partial} partial, {part5_absent} absent by a recorded decision |
| English strings | {en_strings} | every screen string has a row a tenant can rename it by |
| German strings | {de_strings} | the core pack; the rest is served from English and reported |
| Help topics | {help_topics} | one per screen, naming the doors it carries |
| Job handlers | {job_handlers} | run by the database where they can be, by the worker where they must call out |
| Platform components | {platform_components} | what an incident is declared against |
| Providers polled | {platform_dependencies} | an outage below the platform is declared and resolved by the poll |

## 3. What the specification asked for, and what answers it

**Part 2, tenancy.** Composite foreign keys make a cross-tenant reference unrepresentable. Tenant context is transaction-local. A second organisation, structurally unlike the first, is onboarded through doors alone by a suite that reads its own source and refuses any internal call.

**Part 3, the engines.** Configuration is effective-dated with at most one version in force. Rules are JsonLogic, one language everywhere a decision is configurable — approval chains, tax, dimension derivations, permitted combinations. Lifecycles are configuration and their declared effects are executed. Change is promoted, never edited in place; {promotable_surfaces} surfaces are guarded.

**Part 4, the canonical model.** Parties, products, a stock ledger with an owner and a keeper on every position, one document spine for every document type, finance with a numbered journal and a valuation the ledger agrees with to the penny.

**Part 5, the modules.** {part5_built} of {part5_total} capabilities built. Procurement prices a line from the supplier's catalogue and knows blanket, consignment, drop-ship and intercompany orders. Planning fits a season only when it repeats, applies the events the statistics cannot know about, explodes a made item's demand through its bill level by level, and keeps every run so a scenario can be compared with the baseline. Finance derives analysis dimensions from the posting's facts, rules which combinations an account allows, eliminates what a group owes itself in a group ledger, and reconciles a payment provider's settlement statement line by line. The one absent capability, customs documentation, is absent by decision.

**Parts 6 to 10, extensibility, prohibitions, invariants, intelligence.** The boundary that keeps a model out of the transaction path is checked by walking the call graph; the intelligence layer proposes and never applies.

**Parts 11 to 15, the platform under the product.** A dispatch worker that claims, does and reports, with a lease, a timeout and an honest `ambiguous` outcome; a scan-first device client; output templates, labels and print routing; notifications that defer in quiet hours and never suppress.

**Part 16, continuity.** A restore drill that records itself, a release register the deploy proves, a recovery rehearsal on every push: a worker killed before it sent, an endpoint that hangs, an endpoint that fails once.

**Part 17, the platform's own business and its incidents.** A price book, quotes with margin live, contracts and renewals. An incident declared with components and scope, communicated on a timer to every channel from one row, published to a status page through the gateway, reviewed and closed; providers polled, an outage below the platform declared and resolved by the poll.

**Parts 18 to 23, terminology, reporting, cutover, accessibility, guidance, decisions.** Every screen string has a row a tenant can rename it by. Reports have versions and packs, and a pack assembles on a schedule. Opening balances load, reconcile, run in parallel and cut over per domain. {help_topics} help topics name the doors each screen carries. D1–D{product_decisions} are registered and bound.

## 4. How it is proved

The build stands the product up from nothing on every push: an empty PostgreSQL, the host bootstrap, every migration with `--single-transaction`, one organisation seeded with a year of trading. Then {catalogue_checks} catalogue checks, three rehearsals against a stub endpoint, the two-direction door check, the screen-string check, and this document rebuilt and compared.

Each suite asserts its own case count, counts a null verdict as a failure, and rolls its organisation back. A check that exists and is not run is a check that is not there: the runner takes its list from the catalogue and refuses to finish with one left out.

The console, `erp.platform_assurance()`, runs {diagnostic_checks} registered diagnostics and answers green or names what is wrong; every migration ends by requiring it green.

## 5. What is still not proven

- Point-in-time recovery has never been drilled; the dump-and-restore drill records itself quarterly, and a PITR is recorded by the operator once performed.
- The status page is under Cloudflare's own availability, by the recorded decision that a page served from the product's database would die with it.
- German beyond the core pack of {de_strings} strings is served from English and reported as such.
- Customs documentation is not built, by the recorded decision that a declaration nearly right is worse than none.
- Consolidation does not translate currencies: a member in another currency is refused, not summed. Settlement fees are recorded, not posted.
- The live route depends on a secret the owner holds and on the host's production deploy.

## 6. Where to read next

`README.md` for running it; `docs/ARCHITECTURE.md` for how it is enforced and what building it found; `supabase/ops/README.md` for the operator's runbook; `docs/spec/` for the specification.
