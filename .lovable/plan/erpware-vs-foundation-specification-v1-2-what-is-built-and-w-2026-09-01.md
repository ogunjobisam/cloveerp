# ERPWare vs Foundation Specification v1.2 — what is built and what is not

Read-only audit. The spec grew from v1 (499 lines) to v1.2 (2,808 lines, 23 parts, 34 decisions). This maps every part against the 145 migrations, ~319 public `erp_*` functions, and the route/UI tree as they exist today.

## Part-by-part verdict

| Spec part | Status | Notes |
|---|---|---|
| 1 Product definition | Met | Architecture matches: configured-not-coded, event-sourced core |
| 2 Tenancy & isolation | Built | RLS everywhere, adversarial isolation suites, tenant export, deletion with Vault key destruction, purge + grace-period sweep, platform staff (Owner/Operator/Support). Gap: physical-isolation option and region pinning are design statements only; tenant-granular backup/restore not implemented (host-level) |
| 3 Naming & vocabulary | Built | Resource-key layer live, ~440 seeded keys, en-GB product vocabulary, terminology override screen. Gap: en-US variant pack not shipped; a few English fallbacks remain |
| 4 Platform kernel | Built | Identity/access, append-only audit, event store + outbox, config engine, rule engine, state machines, approval engine (depts, bands, named assignment, delegation, escalation), scheduler + dispatch worker, notifications (B9), legislation packs, change sets/promotion/rollback/kill switches, config intelligence behind the AI boundary |
| 5 Canonical domain model | Built | All eleven subsections have tables + invariants: org, parties, items, stock ledger (batch/serial/container, ownership vs custody, cost layers), production, document spine, planning, finance, quality, integration registry |
| 6 Correctness & consistency | Built | Concurrency boundaries, idempotency keys, gapless-vs-unique numbering, projection reconciliation, ambiguous command state, and §6.9's eleven invariants exist as executable assertions run in CI |
| 7.1–7.10 Functional scope | Mostly built | ~85% RPC coverage per `erp_part5_summary`; every module has a screen. API-only tail remains (landed cost allocation UI, excursions, mass change, RFQ, some planning depth) |
| 7.12–7.17 Addendum B surfaces | Built | Approval routing, item-supplier defaults, dimensions (single department object), marshalling areas with print-gating, account determination with no-suspense + coverage assertion, classification + code templates |
| 7.18 AI onboarding interview | Partially built | `onboarding_interview` migrations + suite exist (Sep 1); the conversational UI surface is not among the routes — spec itself calls it "the natural next build" |
| 8 Extension model | Met (as discipline) | No tenant branches in code; deployment-profile concept documented. Level-2 declarative extension (tenant-defined fields/validations) not built |
| 9 Operations & lifecycle | Mostly built | Job health, integration health, assurance screen, go-live checks. Gaps: observability (tracing/SLOs) is platform-level not productised; e-signature manifestation partial; personal-data erasure store (§9.4) not built; per-domain cutover machinery (§9.6) absent |
| 10 Refusals | Met | Enforced structurally; friendly-error layer surfaces refusals with next actions |
| 11 Build sequence | Met | B1–B10 complete + B11 packs; D23's "second organisation" test is now satisfiable via the onboarding flow |
| 12 Starter content packs | Built | Capability registry with dependencies, three presets, base packs (organisation, vocabularies, states, reason codes, tolerances, finance, operations), profile packs, pack application as change sets with acceptance suite |
| 14 Device operations | Not built | No handheld/scan-first UI, no GS1 parsing, no offline queue, no device registration. Zero migrations reference devices/GS1 |
| 15 Output & communications | Started | `output_templates` migration + printer profiles landed (Sep 4). Not built: output_request/render/delivery model, PDF rendering, ZPL labels, print queues, email sender identity/suppression, notification delivery tracking |
| 16 Release & environments | Mostly built | Migration-first with single-transaction discipline, host bootstrap contract, CI suite from empty, validation environments (Sep 4). Gaps: restore drills (D28), schema/app version compatibility policy |
| 17 Support & incident | Partially built | Audited, time-bounded cross-tenant support access exists (platform layer). Not built: severity model, incident workflow, status page, post-incident reviews |
| 18 Commercial & entitlement | Not built | No subscription/entitlement objects, no metering, no restricted-for-non-payment state (suspension exists but is manual) |
| 19 Reporting & analytics services | Partially built | Reporting substrate, KPI definitions, reports screens, AutoPanel over RPCs. Gaps: versioned report definitions as promotable configuration, scheduled distribution packs, external BI contract, NL querying |
| 20 Data migration & import | Built | Import pipeline with staging/validation/preview/load and CSV engine; opening-balance loaders for stock, sales ledger, purchase ledger and nominal as at a date through the movement and journal tables; reconciliation after load per check (D31); batch reversal as reversing journals and movements; parallel-run figures with tolerance; evidence-gated per-domain cutover by a second person, with the evidence kept (D32). `/operations/cutover` (Sep 4) |
| 21 Accessibility | Not addressed | No WCAG audit, statement, or systematic keyboard/contrast pass |
| 22 Guidance & adoption | Partially built | Refusals teach (friendly errors with next action); adoption/insight registers exist (Sep 2). Gaps: contextual help content, role-based first-run guidance, sandbox-with-training-scenarios, demo-seed refusal in live |
| 23 Decisions register | Mostly honoured | D1–D23 from v1 are structural in the build. New-in-v1.2 decisions D24 (scan confirmation), D25/D26 (output subsystem), D28 (restore drill), D29 (restricted state) are not yet implemented because their parts aren't. D31/D32 (migration reconciliation and evidence-gated cutover) are implemented (Sep 4) |

## Headline summary

**Built and working:** the entire foundation (B1–B11), all six Addendum B configuration surfaces, the content-pack system, tenant lifecycle including cryptographic deletion, the platform-owner control plane, and every operational module with screens — roughly the spec's Parts 1–13.

**The four genuinely absent builds** (all new or expanded in v1.2):
1. **Part 14 — Device operations**: the scan-first warehouse application. Largest single gap; a separate UI surface against existing functions.
2. **Part 15 — Output subsystem**: one model for documents, labels, email, notifications. Templates started Sep 4; the render/deliver/archive machinery is not there.
3. **Part 18 — Commercial & entitlement**: subscriptions, metering, entitlement enforcement in the database, the restricted (read/export-only) state.
4. **Part 20 depth — migration reconciliation & cutover**: built Sep 4 — opening-balance loaders as at a date, reconciliation after load, reversal, parallel-run figures and evidence-gated per-domain cutover.

**Smaller gaps:** Part 17 incident/status, Part 19 report governance & scheduled packs, Part 21 accessibility pass, Part 22 contextual help & sandbox, §7.18 interview UI, §9.4 personal-data erasure store.

## Technical notes

- Verified by reading all 145 migration filenames, the parsed v1.2 spec in full, and grep sweeps for each new part's signature objects (`device`, `gs1`, `entitlement`, `output_request`, `parallel_run`, `accessibility` — all zero or near-zero hits).
- No changes proposed; this is a map, not a work order. Say which gap to close and it becomes a plan.
