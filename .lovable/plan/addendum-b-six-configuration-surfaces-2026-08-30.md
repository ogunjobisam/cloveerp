# Addendum B — six configuration surfaces

Six tenant-defined, effective-dated, versioned configuration surfaces. All behaviour comes from
configuration rows; no code path tests for a named department, account, or product family.

Because this is a large body of work, it lands in four phases. Each phase is a self-contained
migration plus its screens, verified before the next starts.

---

## Phase 1 — Departments, approval routing, dimensions

**Data**: `department` (code, label key, manager, parent, default cost centre and dimension set),
`principal_department` (effective-dated membership, one primary), `approval_band` (per department
and object type: value bounds, currency, approver resolution order, sequential or parallel,
re-run lower bands flag), `approver_assignment` (subject principal/group/department, object type,
assigned approver, effective dates, optional bounds, replaces or prepends).

**Resolution**: named assignment → department band → entity fallback. Every resolved chain records
the rule and rule version. Self-approval escalates. Delegation is time-bounded with the assigning
principal as approver of record. Vacancy holds the request and raises an exception. Documents stamp
the requester's primary department at capture and route on the stamped value. Multi-currency bands
resolve on the raise-date rate. Re-approval on material change restarts at the new band.

**Dimensions**: the same `department` row is the finance dimension — one object, not two. Adds
mandatory-by-account rules enforced at posting, derivation from the source event, permitted and
blocked combinations, and project validity dates.

**Events**: `approval.chain.resolved`, `approval.requested`, `approval.granted`,
`approval.rejected`, `approval.escalated`, `approval.delegated`, `approval.reapproval.triggered`.

**Screens**: Administration → Organisation (department hierarchy, memberships), Administration →
Approval routing (bands per department and object type, named assignments, tolerances, escalation
timers, vacancy behaviour), and a chain-preview inquiry that shows who would approve a given value.

## Phase 2 — Account determination and posting classes

**Data**: `item_posting_class` (mandatory, exactly one per item, validated at creation),
`party_posting_class`, and a determination matrix keyed on transaction type, item posting class,
party posting class, site, entity, ledger, legislation pack and reason code.

The rule returns the account **and** the dimension set together. No default-to-suspense: an
unmatched posting is refused and raises an exception. A coverage assertion enumerates every
posting-class × transaction-type × entity combination that can occur and reports gaps; it runs in
the conformance suite before promotion. Posting-class changes are effective-dated and
approval-gated. Document-level overrides are explicit, reasoned, permission-gated and audited.

**Events**: `posting.rule.resolved`, `posting.determination.failed`, `item.posting_class.changed`.

**Screens**: Finance → Account determination (matrix editor, reason-code mappings, coverage report
showing uncovered combinations), and posting class on the item and party master screens.

## Phase 3 — Classification and code composition

**Data**: `classification_axis`, `classification_value` (code, label, abbreviation, effective dates,
optional parent), `item_classification`, mandatory-axes-per-item-category configuration,
`code_template` (versioned ordered segments: axis abbreviation, literal, sequence, check character;
each with length, padding, casing, required flag), bound per item category and entity.

Identity stays an opaque surrogate key. The composed code is a derived label, unique, proposed from
the template and visible before commit. Sequence segments draw from the numbering service.
Templates are versioned and effective-dated; existing items keep their code and record the template
version that produced it. Legacy, customer and supplier codes live in `external_ref`. When an
attribute later diverges from the code, the platform flags it rather than silently re-coding.

Classification vocabularies feed the dimensions from Phase 1. Posting class stays separate from
commercial classification.

**Screens**: Master data → Classification (axes and vocabularies), Master data → Code templates
(segment builder with live preview), and a guided item-creation flow that captures classification
first and previews the composed code before commit.

## Phase 4 — Item defaults, default supplier, release areas

**Data**: `item_supplier` extended with preference rank, default flag per item and site, sourcing
split percentage, approved-for-use flag and effective dates. Replenishment, MRP and manual purchase
order creation take the default for that item at that site; overrides are audited. A regulated
item's default supplier must also sit on the approved supplier list for its item class.

Release areas: a location or zone type configured per site, channel, item category and order type.
Detailed allocation at release commits against the release-area scope only. Two replenishment modes
selectable per item class — pull (wave-driven shortfall raises directed replenishment tasks) and
push (min/max top-up) — both able to run at one site. Release-area stock is allocated stock:
excluded from count scope, unavailable to other demand, and aged back to bulk after a configured
period. Stock the order cannot use is classified per §6.6 and raises replenishment rather than a
shortage. Printing is gated on successful detailed allocation.

**Events**: `release.wave.opened`, `replenishment.task.raised`, `replenishment.task.completed`,
`stock.movement.recorded`, `allocation.detailed.made`, `document.printed`.

**Screens**: Master data → Item supply (default supplier and split), Logistics → Release areas
(zones, mode per item class, min/max, ageing, print trigger), and a release wave workbench.

---

## Cross-cutting

- Every new surface is a configuration object: effective-dated, versioned, change-set promotable,
  and editable through the existing change-request and approval path.
- All labels resolve through the resource-key layer; no literal English in the new screens.
- Every new table carries tenant scoping, RLS, and grants; every new RPC authorises against a named
  permission before reading or writing.
- Conformance additions: the coverage assertion that no posting can fail to determine, and a
  fixture that creates an item under a code template and asserts the composed code, its uniqueness,
  and its independence from the surrogate key.
- AI-assisted setup (§7) is explicitly out of scope here. These six surfaces are what an assistant
  would configure; the onboarding interview comes after they exist.

## Technical notes

New tables live in the `erp` schema alongside the existing configuration objects and follow the
established pattern: tenant column, effective-dated rows, audit and event emission via the existing
helpers, deny-all RLS with access through `security definer` RPCs registered in the allowance table.
Public entry points are `public.erp_*` functions gated by `erp.authorise(...)`, exposed to the UI
through the existing `ActionDialog`, `RpcButton`, record picker and inquiry components.
