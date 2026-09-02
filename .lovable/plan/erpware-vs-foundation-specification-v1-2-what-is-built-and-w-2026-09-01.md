# Clove ERP vs Foundation Specification v1.2 — what is built and what is not

Read-only audit. The spec grew from v1 (499 lines) to v1.2 (2,808 lines, 23 parts, 34 decisions). This maps every part against the 145 migrations, ~319 public `erp_*` functions, and the route/UI tree as they exist today.

## Part-by-part verdict

| Spec part | Status | Notes |
|---|---|---|
| 1 Product definition | Met | Architecture matches: configured-not-coded, event-sourced core |
| 2 Tenancy & isolation | Built | RLS everywhere, adversarial isolation suites, tenant export, deletion with Vault key destruction, purge + grace-period sweep, platform staff (Owner/Operator/Support). Physical isolation and region pinning are recorded as accepted host-level decisions (`physical_isolation_is_host_level`, `region_pinning_is_host_level`, Sep 4) with the evidence of where each is enforced: a dedicated instance built from the same migrations, in the region it is created in. Gap: tenant-granular backup/restore not implemented (host-level) |
| 3 Naming & vocabulary | Built | Resource-key layer live, ~440 seeded keys, en-GB product vocabulary, terminology override screen. Gap: en-US variant pack not shipped; a few English fallbacks remain |
| 4 Platform kernel | Built | Identity/access, append-only audit, event store + outbox, config engine, rule engine, state machines, approval engine (depts, bands, named assignment, delegation, escalation), scheduler + dispatch worker, notifications (B9), legislation packs, change sets/promotion/rollback/kill switches, config intelligence behind the AI boundary |
| 5 Canonical domain model | Built | All eleven subsections have tables + invariants: org, parties, items, stock ledger (batch/serial/container, ownership vs custody, cost layers), production, document spine, planning, finance, quality, integration registry |
| 6 Correctness & consistency | Built | Concurrency boundaries, idempotency keys, gapless-vs-unique numbering, projection reconciliation, ambiguous command state, and §6.9's eleven invariants exist as executable assertions run in CI |
| 7.1–7.10 Functional scope | Mostly built | ~85% RPC coverage per `erp_part5_summary`; every module has a screen. API-only tail remains (landed cost allocation UI, excursions, mass change, RFQ, some planning depth) |
| 7.12–7.17 Addendum B surfaces | Built | Approval routing, item-supplier defaults, dimensions (single department object), marshalling areas with print-gating, account determination with no-suspense + coverage assertion, classification + code templates |
| 7.18 AI onboarding interview | Partially built | `onboarding_interview` migrations + suite exist (Sep 1); the conversational UI surface is not among the routes — spec itself calls it "the natural next build" |
| 8 Extension model | Met (as discipline) | No tenant branches in code; deployment-profile concept documented. Level-2 declarative extension (tenant-defined fields/validations) not built |
| 9 Operations & lifecycle | Mostly built | Job health, integration health, assurance screen, go-live checks. Gaps: observability (tracing/SLOs) is platform-level not productised; e-signature manifestation partial. §9.4 personal-data erasure built Sep 4: `erp_ref.personal_data_field` and `personal_data_exemption` registers checked against the catalogue, `erp.erasure_request` executed by a second person with a certificate, the ledger's copies redacted through the one mutation the append-only guard permits (`/administration/erasure`). §9.6 per-domain cutover built with Part 20 |
| 10 Refusals | Met | Enforced structurally; friendly-error layer surfaces refusals with next actions |
| 11 Build sequence | Met | B1–B10 complete + B11 packs; D23's "second organisation" test is now satisfiable via the onboarding flow |
| 12 Starter content packs | Built | Capability registry with dependencies, three presets, base packs (organisation, vocabularies, states, reason codes, tolerances, finance, operations), profile packs, pack application as change sets with acceptance suite |
| 14 Device operations | Not built | No handheld/scan-first UI, no GS1 parsing, no offline queue, no device registration. Zero migrations reference devices/GS1 |
| 15 Output & communications | Started | `output_templates` migration + printer profiles landed (Sep 4). Not built: output_request/render/delivery model, PDF rendering, ZPL labels, print queues, email sender identity/suppression, notification delivery tracking |
| 16 Release & environments | Mostly built | Migration-first with single-transaction discipline, host bootstrap contract, CI suite from empty, validation environments (Sep 4). Gaps: restore drills (D28), schema/app version compatibility policy |
| 17 Support & incident | Partially built | Audited, time-bounded cross-tenant support access exists (platform layer). Not built: severity model, incident workflow, status page, post-incident reviews |
| 18 Commercial & entitlement | Built | Plans, subscriptions, entitlement kinds enforced in the database, the restricted state, capabilities per plan (Sep 4). Metering closed Sep 4: every meter in `erp_meta.meter_kind` is recorded by the transaction path it names (documents on first commitment, movements at the ledger table, messages on delivery, active users by a scheduled measure), asserted by `erp.assert_meters_recorded()` so a plan limit that reads a meter is a limit that can be reached |
| 19 Reporting & analytics services | Partially built | Reporting substrate, KPI definitions, reports screens, AutoPanel over RPCs. Gaps: versioned report definitions as promotable configuration, scheduled distribution packs, external BI contract, NL querying |
| 20 Data migration & import | Built | Import pipeline with staging/validation/preview/load and CSV engine; opening-balance loaders for stock, sales ledger, purchase ledger and nominal as at a date through the movement and journal tables; reconciliation after load per check (D31); batch reversal as reversing journals and movements; parallel-run figures with tolerance; evidence-gated per-domain cutover by a second person, with the evidence kept (D32). `/operations/cutover` (Sep 4) |
| 21 Accessibility | Built | WCAG 2.2 A/AA audit as a register (`erp_ref.accessibility_criterion`, 55 criteria: 43 met, 2 partially met, 10 not applicable) with the statement generated from it (`/administration/accessibility`); keyboard and contrast pass (skip link, focus-visible ring, reduced motion, aria-current, labels on every field, scope on headers, tokens recomputed to 4.5:1 and 3:1); `src/lib/accessibility.test.ts` computes contrast from the tokens and sweeps the source on every build; `erp.assert_accessibility_register_sound()` (Sep 4) |
| 22 Guidance & adoption | Built | Refusals teach (friendly errors with next action); adoption/insight registers exist (Sep 2). Sep 4: contextual help as a register (`erp_ref.help_topic`, one topic per launchpad tile and Home, checked by the build in both directions, with an organisation's own note beside it through `help.local.*`), the help button in the shell; role-based first-run guidance (`erp_ref.first_run_step`, 28 steps across 9 guides, filtered by the caller's permissions, progress per person) on Home; training scenarios with database-evaluated completion checks (`erp_ref.training_scenario`, an organisation's own from the same checks), refused in a live environment; the demo seeds refused in live by the platform; every setting states its consequence; `erp.adoption_report()` counting what is ageing without naming anyone. `/administration/adoption`; `erp.assert_guidance_sound()` |
| 23 Decisions register | Mostly honoured | D1–D23 from v1 are structural in the build. New-in-v1.2 decisions D24 (scan confirmation), D25/D26 (output subsystem), D28 (restore drill), D29 (restricted state) are not yet implemented because their parts aren't. D31/D32 (migration reconciliation and evidence-gated cutover) are implemented (Sep 4) |

## Headline summary

**Built and working:** the entire foundation (B1–B11), all six Addendum B configuration surfaces, the content-pack system, tenant lifecycle including cryptographic deletion, the platform-owner control plane, and every operational module with screens — roughly the spec's Parts 1–13.

**The four genuinely absent builds** (all new or expanded in v1.2):
1. **Part 14 — Device operations**: the scan-first warehouse application. Largest single gap; a separate UI surface against existing functions.
2. **Part 15 — Output subsystem**: one model for documents, labels, email, notifications. Templates started Sep 4; the render/deliver/archive machinery is not there.
3. **Part 18 — Commercial & entitlement**: built Sep 4 — subscriptions, entitlement enforcement in the database, the restricted (read/export-only) state; the meters wired into their transaction paths and asserted recorded.
4. **Part 20 depth — migration reconciliation & cutover**: built Sep 4 — opening-balance loaders as at a date, reconciliation after load, reversal, parallel-run figures and evidence-gated per-domain cutover.

**Smaller gaps:** Part 17 incident/status, Part 19 report governance & scheduled packs, §7.18 interview UI. Part 21 accessibility, Part 22 guidance & adoption and §9.4 personal-data erasure were closed Sep 4.

## Technical notes

- Verified by reading all 145 migration filenames, the parsed v1.2 spec in full, and grep sweeps for each new part's signature objects (`device`, `gs1`, `entitlement`, `output_request`, `parallel_run`, `accessibility` — all zero or near-zero hits).
- No changes proposed; this is a map, not a work order. Say which gap to close and it becomes a plan.
