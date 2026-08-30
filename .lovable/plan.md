# ERPWare — Advice on the remaining gaps

Seven gaps remain from the audits. Below is an assessment of each — what it actually costs you, and what I recommend doing (or deliberately not doing). Approving this plan means I implement the "Recommended now" items; the rest stay documented as conscious decisions.

## Recommended now (high value, low risk)

### 1. Audit-log screen (gap 6) — build it
The data already exists: change sets, approvals, document transitions, and the audit/event tables all record who did what, when. What's missing is only a UI. A new `/administration/audit` screen with filters by tenant, user, object type, action, and date range, reading existing audit/change-set RPCs. This is the single most-requested ERP admin feature and closes the last "requested but never built" item.

### 2. Triage the 12 database security-lint findings (gap 3)
Most are likely intentional (SECURITY DEFINER helpers with written rationale, write-allowance wrappers). For each: either fix it, or record it as an accepted finding in the security memory so future scans don't re-flag it. No behavior change — just a clean security posture on paper.

### 3. Finish resource-key coverage for remaining strings (gap 4)
Sweep the frontend for English literals that bypass `t()` (mostly fallbacks and a few hard-coded labels) and seed the corresponding keys. Small, mechanical, keeps spec §7 honest. Low priority if terminology overrides aren't used yet.

## Decide, don't build (judgment calls)

### 4. One user = one tenant vs the switcher (gap 1)
Spec §2.1 says exactly one tenant per identity; the switcher deliberately relaxes this. **My advice: keep the switcher.** It's essential for your demo/exploration workflow and for real consultants/admins who serve multiple tenants. The security boundary (RLS) doesn't care. If you ever need strict §2.1 compliance for a customer, enforce it per-tenant via a policy flag rather than ripping the switcher out. No action needed now — just record the decision.

### 5. Per-tenant encryption keys / crypto-shredding (gap 2)
The big one. Options:

- **Do nothing (recommended for now).** Postgres RLS already isolates tenants; deletion purges rows. Encryption keys only matter if you need defense against a database-level breach or contractual "crypto-shredding" deletion guarantees.
- **Half-measure (pointless):** app-level encryption of a few columns — key management complexity, breaks SQL querying, little real protection.
- **Full measure (defer until a customer demands it):** per-tenant DEKs in a KMS wrapping sensitive columns, deletion = destroy key. This is a multi-day build with real operational risk (lose the key, lose the data).

**My advice:** document it as a known spec deviation, revisit only when a compliance requirement or enterprise deal forces it.

### 6. Part 5 module coverage partials (finance 69%, logistics/reporting 67%, planning 70%)
These percentages measure spec-feature breadth, not brokenness — everything measured works. Closing them means implementing more spec sub-features (e.g. deeper logistics docs, more report types). **My advice:** pick based on which module you'll demo or sell first, and expand that one to ~100%, rather than spreading effort. Say which module matters and I'll plan it.

### 7. RPCs without UI (gap 5)
The tail (landed cost allocation, excursions, mass change, etc.) is API-only. **My advice:** add UI on demand. `AutoPanel` makes surfacing an RPC result cheap, but screens nobody uses are clutter. Add them when a workflow actually needs them.

## Proposed work order if approved

1. Build the audit-log screen with filters (item 1)
2. Triage and disposition the 12 lint findings (item 2)
3. Resource-key sweep (item 3)
4. Record decisions on items 4–7 in the build report / security memory
5. Re-run typecheck + build + a quick authenticated spot-check of the new screen
