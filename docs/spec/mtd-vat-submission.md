# MTD VAT submission

Submitting a finalised VAT return to HMRC from Clove ERP, and what it takes for
Smartever Ltd to get production credentials and HMRC recognition.

Drafted 13 Oct 2026, against main at `fef5b1a`. Supersedes the line "HMRC API
submission and MTD recognition" in `simplification-review.md` §10 (out of
scope) only when the owner opens it. Until then the bridging route of V1 and
V2 stands and this document is the plan, not a commitment.

## 1. Decision this asks for

- **Build it only when a buyer asks for direct filing.** Bridging (V2) is a
  valid MTD route; recognition is not needed to sell.
- **When built, it adds no step to the VAT return.** Finalise stays one press
  (D14). Submission is a second, separate press on a finalised return, and a
  company that does not connect HMRC never sees it.
- **D14 holds.** The return gains no filed state. A submission is its own
  append-only record pointing at the return, carrying HMRC's receipt.

## 2. What is already built

Read from the tree on 13 Oct 2026. Confirm before changing.

- `20261001100000_a_vat_return_is_finalised_from_its_period.sql` (V1):
  `tax.vat_return` setting (frequency, stagger, scheme, Northern Ireland),
  `erp.vat_obligations()` derived not stored, `erp.finalise_vat_return()`,
  frozen return with the nine boxes, entries and digest in its attributes.
  Refuses non-standard schemes and Northern Ireland (D7).
- `20261001200000_a_finalised_vat_return_is_exported_from_its_records.sql`
  (V2): `erp.vat_return_export()` re-derives the entries and refuses changed
  records; the `json` form already uses the MTD body field names, with
  `periodKey` null because only HMRC's obligations API gives it.
- `20261004965000_a_carrier_books_through_its_own_systems.sql`: the pattern to
  copy. Per-organisation credentials in Supabase Vault behind a
  `credential_ref`, an `erp.external_system` on an adapter, outbound commands
  through `erp.submit_command()` drained by the dispatch worker
  (`worker/src/core/`), an adapter proved against a recorded exchange
  (`src/lib/carriers/easypost.test.ts`).

## 3. How HMRC differs from EasyPost

These four differences drive the design. Each is a place to get it wrong.

- **One application, many clients.** The OAuth client ID and secret are
  Smartever's, issued once per Developer Hub application (sandbox and
  production are separate applications). They are fleet secrets, not
  organisation credentials. They go to every client project through
  `.github/workflows/fleet_secrets.yml` and are never in the repository — the
  repository is public.
- **The organisation's grant is delegated, not a key.** Each company's VAT
  user signs in with their Government Gateway login and grants `read:vat` and
  `write:vat`. The result is an access token (short-lived) and a refresh
  token (long-lived, then the user must sign in again). Both go to Vault in
  that client's project; only references are kept.
- **One redirect address.** HMRC registers a short, fixed list of redirect
  URIs per application; a wildcard over `*.cloveerp.com` is not possible. The
  callback is therefore one route on the apex, `cloveerp.com/api/hmrc/callback`,
  and the `state` parameter carries the client code, the organisation, the
  company and a single-use nonce. The Worker resolves the client's project
  through the directory (`/api/directory/<host>`) and exchanges the code
  there.
- **Fraud prevention headers describe the person, not the server.** Every
  call carries `Gov-Client-*` and `Gov-Vendor-*` headers about the device,
  browser and network path of the person who pressed Submit. The dispatch
  worker runs later and elsewhere, so the headers must be captured at the
  press and carried in the command. See §6.

## 4. Scope

In:

- Connect and disconnect HMRC per company (VRN).
- Read HMRC's obligations and reconcile them with `erp.vat_obligations()`.
- Submit a finalised return; keep HMRC's receipt.
- Read back a submitted return (`View VAT Return`) to prove what HMRC holds.

Out, named so they are not assumed:

- Liabilities, payments and penalties endpoints. Next, not now.
- Agent access (an accountant filing for many clients through an agent
  services account).
- MTD Income Tax.
- Cash, flat rate and Northern Ireland returns — already refused at finalise.
- Amending a submitted return. HMRC takes one submission per period; an
  error is corrected on the next return, as D14 already says.

## 5. Data and doors

Names follow the house pattern; adjust to the generators.

- **`erp.hmrc_connection`** — one row per company: VRN, mode
  (`sandbox` | `production`), `credential_ref` for the token pair, scopes
  granted, connected by and when, refresh token expiry, state
  (`connected` | `expired` | `revoked`). Tenant-scoped, row security from
  `erp.apply_row_security()`.
- **`erp.hmrc_oauth_state`** — single-use nonces, ten-minute life, consumed
  by the callback. Purged by the minute pass.
- **`erp.vat_submission`** — append-only, one per return accepted by HMRC:
  the return, `periodKey`, the body sent and its sha256 (must equal the V2
  `json` export's), HMRC's `processingDate`, `formBundleNumber`,
  `paymentIndicator`, `chargeRefNumber` where given, the `X-Correlation-Id`,
  who declared and when. A unique key on (company, periodKey). A trigger
  refuses update and delete outside a purge.
- **`erp.vat_submission_attempt`** — every attempt, accepted or refused, with
  HMRC's error code and message. This is what the screen shows when a
  submission fails.
- **Permission** — new code `finance.file_vat`. Finalising
  (`finance.close_period`) and filing are separate so a firm can split them.
  Connecting is `administration.integrate`, as carriers are.
- **Doors**
  - `erp_hmrc_connect_start(company)` → the authorise URL with a fresh state.
  - `erp_hmrc_connection(company)` → connected or not, mode, expiry.
  - `erp_hmrc_disconnect(company)` → revokes and clears the Vault secrets.
  - `erp_hmrc_obligations(company)` → submits `vat.obligations.read` and
    answers with what the last read returned, matched to Clove's periods.
  - `erp_submit_vat_return(return, declaration, client_context)` → refuses
    unless the return is finalised, unsubmitted, its period matches an open
    HMRC obligation, the V2 export re-derives cleanly, and the declaration is
    true; then submits `vat.return.submit` with the captured headers.
- **Refusals**, registered, each named: not connected, connection expired,
  no matching HMRC obligation, period already fulfilled at HMRC, records
  changed since finalising, declaration not given, header context missing.
- **Events**: `hmrc.connected`, `hmrc.disconnected`, `vat_return.submitted`,
  `vat_return.submission_refused`.

The declaration is HMRC's required wording, shown in full beside the Submit
button, and the person ticks it. `finalised: true` is sent only when it is.

## 6. Fraud prevention headers

Connection method: `WEB_APP_VIA_SERVER`. Check the field list against HMRC's
current specification at build time — it changes.

Captured in the browser at the press, sent in `client_context`:

- `Gov-Client-Browser-JS-User-Agent`, `Gov-Client-Screens`,
  `Gov-Client-Window-Size`, `Gov-Client-Timezone`.
- `Gov-Client-Device-ID` — a random id kept in the browser's storage, made
  once per browser.

Added by the Cloudflare Worker that receives the press:

- `Gov-Client-Public-IP`, `Gov-Client-Public-IP-Timestamp`,
  `Gov-Client-Public-Port`.
- `Gov-Client-User-IDs` — the Clove principal id, never the email.
- `Gov-Client-Multi-Factor` — from the session's authentication factors.

Added by the dispatch worker when it calls HMRC:

- `Gov-Client-Connection-Method`, `Gov-Vendor-Product-Name`,
  `Gov-Vendor-Version`, `Gov-Vendor-License-IDs` (the hashed subscription
  id), `Gov-Vendor-Public-IP`, `Gov-Vendor-Forwarded` (the hops: Cloudflare
  edge → Worker → dispatch worker).

Open points to settle with HMRC's Software Developer Support Team
(SDSTeam@hmrc.gov.uk) before applying:

- **Client source port.** Cloudflare does not hand the Worker the client's
  source port as standard. Either find it or document why it cannot be
  collected; HMRC accepts an omission it is told about, not a silent one.
- **Asynchronous submission.** The headers describe the press, not the
  moment the worker sends. Confirm HMRC accepts the captured context with
  the timestamp of the press.

The captured context is personal data. Keep it on the command only until the
attempt settles, then reduce it to the hashes HMRC's audit needs. Name the
retention in the privacy policy.

## 7. Flow

1. Administrator connects HMRC for a company → redirect to HMRC → sign in,
   grant → callback on the apex → code exchanged in the client's project →
   tokens to Vault → `hmrc.connected`.
2. VAT screen reads `erp_hmrc_obligations()` beside Clove's own periods. A
   period HMRC has that Clove does not (or the reverse) is shown as a
   mismatch, most often a wrong stagger in `tax.vat_return`.
3. Finance finalises as today (V1). Nothing changes.
4. A person with `finance.file_vat` opens the finalised return, reads the
   declaration, ticks it, presses Submit. The browser sends its context.
5. The dispatch worker refreshes the token if needed, sends the V2 `json`
   body with the matched `periodKey`, and hands the answer back:
   `erp.vat_submission` on success, an attempt row either way.
6. The return reads "Submitted to HMRC" from the submission, not from a
   state of its own.

## 8. Graph

```yaml
nodes:
  - id: V3
    title: Connect a company to HMRC
    kind: build
    needs: [V2]
    pr: PR15
    proves: erp_test.hmrc_connection_suite

  - id: V4
    title: Read HMRC obligations and match them to Clove periods
    kind: build
    needs: [V3]
    pr: PR15
    proves: erp_test.hmrc_connection_suite

  - id: V5
    title: Capture and assemble fraud prevention headers
    kind: build
    needs: [V3]
    pr: PR16
    proves: src/lib/hmrc/fraud-headers.test.ts

  - id: V6
    title: Submit a finalised return and keep the receipt
    kind: build
    needs: [V4, V5]
    pr: PR16
    proves: erp_test.vat_submission_suite

  - id: V7
    title: VAT returns screen gains Connect and Submit
    kind: screen
    needs: [V6]
    pr: PR17
    proves: e2e vat-submission.spec.ts against the sandbox
```

## 9. Proof

- **Database.** `erp_test.hmrc_connection_suite` (connect, expiry, revoke,
  state reuse refused, cross-tenant refused) and `erp_test.vat_submission_suite`
  (every refusal in §5, one submission per period, receipt immutable, body
  digest equals the export's).
- **Adapter.** `src/lib/hmrc/*.test.ts` against recorded sandbox exchanges,
  as `easypost.test.ts` is. No live call in CI.
- **Headers.** Every header assembled is checked against HMRC's Test Fraud
  Prevention Headers API from a sandbox run before applying for production.
- **Sandbox run.** Test users from the Create Test User API; the
  `Gov-Test-Scenario` header for the refusals HMRC can simulate.

## 10. Credentials and recognition — Smartever's side

Not code. Done once, by the owner.

- Developer Hub account and organisation in the name of Smartever Ltd.
- Sandbox application: VAT (MTD), Create Test User, Test Fraud Prevention
  Headers. Sandbox client ID and secret to the fleet secrets as
  `HMRC_SANDBOX_CLIENT_ID` / `HMRC_SANDBOX_CLIENT_SECRET`.
- Redirect URIs registered: `https://cloveerp.com/api/hmrc/callback`, and the
  staging Worker's address for sandbox only.
- Before requesting production credentials:
  - privacy policy and terms and conditions URLs on cloveerp.com covering the
    software;
  - an answer on penetration testing (cost: check budget before buying one);
  - service management and security answers.
- Request production credentials; HMRC then sends its questionnaire. Six
  months to complete it.
- Once recognised: say "HMRC recognised" only. Never "approved" or
  "accredited". Until then, the site says the return is computed and exported
  for bridging software, and nothing about being MTD ready.

## 11. Budget

Estimate, not measured: V3–V6 about a week of focused work, most of it §6 and
the apex callback; V7 two days; HMRC's process a few weeks of elapsed time
after the sandbox run, outside the build.
