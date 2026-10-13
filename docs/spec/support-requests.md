# Support requests

How an organisation asks Clove for help, how the published response times are
measured against what it asked, and where support ends and chargeable work
begins.

Drafted 13 Oct 2026, against main at `fef5b1a`. Fills the gap the
specification already assumes: §17.1 says support access names "a reference to
the organisation's own request", and nothing in the product makes one.

## 1. Decision this asks for

- **Build it before the first founding customer goes live.** It is the one
  support service every buyer will ask about, and the response times are
  already published (`erp_ref.support_severity`) with nothing measuring them.
- **The request lives in the organisation's own database.** It is the
  organisation's record, readable without asking anyone, as `erp.support_access`
  is. The control plane sees a summary of every client's open requests; it
  never holds the conversation.
- **The clock is the product's, not the agent's.** Response and update targets
  come from the published table and are stamped on the request when raised.
  Nobody edits a target, and a missed one stays missed.
- **Support and chargeable work are told apart on the request.** Anything that
  will take more than half a day, or is advice beyond a quick answer, is
  marked chargeable with an estimate, and no work starts until the
  organisation accepts it.

## 2. What is already built

Read from the tree on 13 Oct 2026. Confirm before changing.

- `20260904320000_part17_support_and_incidents.sql`: `erp_ref.support_severity`
  (sev1–sev4, response and update minutes, `requires_review` on sev1 and sev2);
  `erp.support_access` with `request_reference` already on it, expiring,
  append-only, visible to the organisation; `erp.support_action` for writes.
- `20260904610000_commercial_contracts.sql`: `erp_meta.contract.support_severity_code`,
  the severity the contract's support tier covers, sold through the price
  book's `support_tier` items.
- `20261012060000_incidents_reach_every_client.sql`: a client deployment has its
  own console; the control plane declares incidents and `fleet_sweep.yml`
  carries them every ten minutes.
- `.github/workflows/fleet_poll.yml`: hourly health of every client written on
  the control plane's register — the route a request summary takes.
- `supabase/functions/enquiry`: the precedent for "stored, then emailed to
  `erp_meta.platform_staff`, and 'notified' only when the provider named the
  message".

## 3. Scope

In:

- Raise a request with a proposed severity, a description, the screen or
  document it concerns, and attachments.
- A conversation on the request between the organisation and platform staff.
- Response and update clocks against the published table, paused only while
  the request waits on the organisation.
- Severity agreed, and disagreement escalated, as §17.2 says.
- Chargeable work proposed with an estimate and accepted or declined.
- Support access sessions shown under the request they were opened for.
- A fleet queue on the control plane; a client's requests on its own console.
- A monthly response report per organisation: targets met and missed.

Out:

- Billing chargeable work. The request records the acceptance; the quote and
  invoice go through the existing commercial documents.
- Phone support. A call is logged against a request by staff, not taken by the
  product.
- A public knowledge base. Help topics (`src/routes/help.tsx`) stay where they
  are; the raise screen links to the topic for the screen it was raised from.
- Customer satisfaction scores.

## 4. Data

Names follow the house pattern; adjust to the generators.

- **`erp.support_request`** — tenant-scoped. Number (`SR-`, never reset),
  raised by and when, subject, description, the screen route and document it
  concerns, proposed severity, agreed severity, status, classification
  (`support` | `chargeable`), the contract's covered severity at raise time,
  and the targets stamped at raise: `respond_by`, `update_every_minutes`.
  Targets are re-stamped only when the agreed severity changes, as a recorded
  act.
- **`erp.support_request_message`** — append-only. Author (an organisation
  user, or "the platform" with the staff member held platform-side only, as
  incidents do), body, attachments, whether it is internal to staff
  (internal messages never reach a tenant session).
- **`erp.support_request_event`** — append-only: raised, responded, severity
  proposed, severity agreed, severity disputed, escalated, waiting on
  organisation, resumed, marked chargeable, estimate accepted or declined,
  resolved, reopened, closed. The clocks are computed from these rows, never
  stored as running totals.
- **`erp.support_access.request_reference`** — already there; now validated
  against `erp.support_request` when given, so a session names a real request.

Statuses, one lifecycle through `erp.open_document()` like every other
document type: `open` → `responded` → `waiting_on_organisation` ⇄ `in_progress`
→ `resolved` → `closed`. A resolved request closes itself after seven days
unless reopened. Closed is terminal; a new problem is a new request.

## 5. The clocks

- **Response.** From raise to the first message by platform staff that is not
  internal. Target: the agreed severity's `response_within_minutes`, stamped at
  raise.
- **Update.** From each staff message to the next, while the request is open
  or in progress. Target: `update_every_minutes`. A missed update is counted
  once per interval missed, as an incident's cadence is.
- **Pause.** Only `waiting_on_organisation` stops the clocks. Staff setting it
  must say what they are waiting for; the organisation replying resumes it.
- **Hours.** Sev1 and sev2 run on the clock around the day; sev3 and sev4 run
  on business hours (09:00–17:30 UK, Monday to Friday, excluding bank holidays
  in England and Wales). The business calendar is a register, not a constant.
- **Coverage.** Where the contract's covered severity is lower than the one
  agreed (a sev1 raised on a tier that covers sev2), the request is still
  taken at sev1 and handled first; its target is the covered tier's, and the
  request says so. Owner to confirm this reading of the price book before
  build.

## 6. Severity agreed, not imposed

- The organisation proposes a severity when raising.
- Staff may propose a different one with a reason. The organisation accepts or
  disputes.
- A dispute escalates to the platform owner and both proposals stand on the
  request until the owner records the agreed severity with a reason. Nobody
  changes it silently (§17.2: "disagreement escalates rather than being
  resolved unilaterally").
- A sev1 or sev2 request offers staff "declare an incident from this", which
  opens an incident naming the request; the post-incident review then covers
  it (`requires_review`).

## 7. Support or chargeable

- Staff mark a request chargeable with a reason and an estimate in
  consultancy days (half-day granularity).
- The organisation accepts or declines on the request. Accepted creates a
  draft quote line through the commercial documents for staff to issue;
  declined returns the request to support with a note of what support will
  and will not cover.
- The clocks keep running on the support part of a chargeable request: the
  response is still owed.
- The boundary is published on the help page in one sentence: under half a
  day and within how the product works is support; configuration projects,
  training sessions and custom reporting are chargeable.

## 8. Doors

- `erp_raise_support_request(subject, description, proposed_severity, route, document, attachments)`
  under `support.raise`.
- `erp_support_requests(filter)` — the organisation's requests; a user without
  `support.read` sees only their own.
- `erp_support_request(id)` — one request, its messages (internal ones never
  returned to a tenant session), events, clocks and the support access
  sessions that name it.
- `erp_reply_to_support_request(id, body, attachments)`.
- `erp_agree_support_severity(id, accept)` and `erp_dispute_support_severity(id, reason)`.
- `erp_answer_support_estimate(id, accept, note)`.
- `erp_reopen_support_request(id, reason)` — within seven days of resolution.
- Platform side (rank-gated, on the client's own console): respond, set
  waiting, propose severity, mark chargeable, resolve, record the agreed
  severity after a dispute (owner only), declare an incident from it.
- `erp_support_response_report(month)` — targets met and missed, by severity.

New permission codes: `support.raise` (default on every full-seat role in the
starter packs), `support.read` (administrators). Every door asserts its own
governance in its migration.

## 9. Telling people

- **Raised** — the raiser gets an email with the number and the target; platform
  staff get an email at once from the client's own project, the enquiry
  function's pattern: "notified" is written only when the provider named the
  message. A sev1 also sends to every staff member marked on call.
- **Staff replied, waiting on you, resolved** — the raiser and anyone who
  replied on the request.
- **A target is 15 minutes from missing** — staff, by email.
- The fleet summary (open requests by client and severity, oldest unanswered,
  targets missed) is carried to the control plane by the hourly poll and shown
  in a Support card on Today, linking to each client's console. The emails,
  not the poll, are what meet a 30-minute response.

## 10. Graph

```yaml
nodes:
  - id: SR1
    title: Support request, messages and events
    kind: build
    needs: []
    pr: PR-S1
    proves: erp_test.support_request_suite

  - id: SR2
    title: Response and update clocks, pause and business hours
    kind: build
    needs: [SR1]
    pr: PR-S1
    proves: erp_test.support_clock_suite

  - id: SR3
    title: Severity agreed, disputed and escalated
    kind: build
    needs: [SR1]
    pr: PR-S2
    proves: erp_test.support_request_suite

  - id: SR4
    title: Chargeable work with an accepted estimate
    kind: build
    needs: [SR1]
    pr: PR-S2
    proves: erp_test.support_request_suite

  - id: SR5
    title: Emails at raise, reply, resolution and near-miss
    kind: build
    needs: [SR2]
    pr: PR-S3
    proves: erp_test.support_notification_suite

  - id: SR6
    title: Raise and request screens; platform console and Today card
    kind: screen
    needs: [SR3, SR4, SR5]
    pr: PR-S3
    proves: e2e support-request.spec.ts

  - id: SR7
    title: Fleet summary carried by the hourly poll
    kind: build
    needs: [SR2]
    pr: PR-S3
    proves: supabase/ci/fleet_poll.sh reports open requests per client
```

## 11. Proof

- `erp_test.support_request_suite`: raise refused without `support.raise`; a
  user without `support.read` sees only their own; internal messages never
  reach a tenant session; events and messages refuse update and delete; a
  severity changes only by agreement or by the owner after a dispute; a
  chargeable request cannot be worked as chargeable until accepted;
  `support_access.request_reference` refuses an unknown request; no door
  crosses tenants.
- `erp_test.support_clock_suite`: response met and missed at each severity;
  updates missed counted once per interval; waiting pauses and resuming
  restarts; sev3 raised at 17:00 Friday is due at the right hour on Monday,
  and over a bank holiday; coverage lower than the agreed severity applies the
  covered target and says so.
- `erp_test.support_notification_suite`: staff and raiser emails at raise;
  "notified" only with a provider id; near-miss once per target.
- Permissions are proved by the existing grant, door-isolation and refusal
  suites, extended — not by walking the screens.

## 12. Budget

Estimate, not measured: SR1–SR4 about four days; SR5 and SR7 two; SR6 three.
Roughly two weeks of focused work.
