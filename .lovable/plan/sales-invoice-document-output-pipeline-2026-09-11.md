# Sales invoice document output pipeline

## Goal

Build one production-shaped document path for **sales invoices** only: manage a versioned template, preview it against a real invoice, issue an immutable numbered PDF into private storage, and retrieve the exact issued bytes for reprint.

This extends the existing Output and printing screen and reuses the current output-template, terminology, permission, audit, document-lineage, and generated row-security architecture. It does not add label printing or another document type.

## Delivery sequence

Deliver this as three reviewable PRs, each leaving the branch green:

1. **Schema, contract and assertions** — permissions, template lifecycle, legal fields, immutable issue/sequence model, invoice contract, authorising routines, RLS, audit and CI assertions.
2. **Server-side PDF rendering and private storage** — authenticated rendering function, embedded fonts/logo, preview lifecycle, issue archive and exact-byte reprint.
3. **Screens** — extend Output and printing and the existing sales-invoice record page, then add the focused UI tests.

## PR 1 — Schema, contract and assertions

Add forward-only migrations that:

- Add the `document` permission module and the requested permission codes:
  - `document.template.manage`
  - `document.issue`
  - `document.reprint`
- Grant the new permissions through the existing role templates:
  - template management to roles already responsible for output configuration;
  - sales-invoice issue and reprint to the existing finance and sales roles that already hold `sales.invoice`;
  - preserve composable roles and existing segregation-of-duties rules.
- Reuse `erp.output_template` and `erp.output_template_version` as the document-template/version store rather than creating a competing template system.
- Make draft creation and activation separate authorised routines. Activation supersedes the previous active version atomically, with a unique partial index enforcing one active version per organisation and document type.
- Add `erp.document_sequence`, scoped by organisation and document type, with an immutable prefix and an atomically incremented monotonic number. Sequence reservations are never deleted or reused.
- Add `erp.document_issue`, scoped by organisation, recording the source invoice, exact template/version, issuer/time, storage object path, checksum, sequence number, delivery state, optional `replaces_issue_id`, and the **fully resolved sales-invoice contract JSON frozen at issue time**.
- Store resolved party identity and address values in that contract rather than pointers alone. A later source edit or partner merge therefore cannot change the explanation of what was issued.
- Preserve failed sequence reservations as failed/void issue attempts rather than recycling their numbers. Protect issued rows and sequence identity fields from later mutation.
- Register every new table in `erp_meta.table_policy`, regenerate row security, attribution, audit, and append-only protections where applicable, and keep organisation identity derived by `erp.require_tenant_id()` rather than accepted as input.

## 2. Declare and validate the sales-invoice contract

Add an explicit database contract routine for `sales_invoice` containing:

- header: issued number, document number, dates including tax point, currency, references, and replacement link;
- issuing company: resolved legal name, company registration number, VAT registration number, registered office, and logo provenance/checksum;
- customer: resolved legal/trading name, tax identifier where present, and the frozen invoice address snapshot, independent of any later partner merge;
- lines: product/code, description, quantity, unit, unit price, discount, net, VAT code/rate, VAT, and gross;
- tax summary: grouped VAT rate/net/VAT totals;
- totals: net, VAT, gross, and total VAT in sterling.

Add the missing structured company setup needed by that contract: a registered-office address and an explicit tax-point value or deterministic tax-point derivation captured on the invoice. Use the existing entity tax-registration table for VAT registration status/number.

Before reserving an issue number, validate the invoice type and required data. For a VAT-registered issuing company, refuse the issue when any required legal field is absent. Each refusal identifies the exact missing field and supplies the appropriate existing destination:

- company/VAT/registered-office problems → Organisation and approval routing;
- tax point or line tax data → the invoice record;
- missing customer/address data → Business partners.

Register these refusals in the existing refusal/resource layer so the UI shows plain language and retains technical detail behind its existing disclosure.

Define amendment as an issue-ledger operation:

- **Issued but not sent:** void the original issue, retain its number and exact file, allocate a new number, create a replacement issue linked through `replaces_issue_id`, and show the replaced number on the new invoice.
- **Already sent:** refuse amendment and direct the user to raise a credit note. The original issue remains unchanged.
- Assert both paths, including that no number is reused and no source invoice is silently overwritten.

## PR 2 — Add authenticated PDF rendering and the private archive

Add an authenticated TanStack server function named `renderSalesInvoice`, running in the application’s server-side edge runtime. It follows the current stack boundary rather than adding another Supabase Edge Function.

Use **`pdf-lib` with `@pdf-lib/fontkit` and bundled Noto Sans regular/bold font files**. Before implementation, prove with a fixture that this exact renderer can:

- paginate a 200-line invoice without clipping or splitting a line incorrectly;
- keep the tax summary and totals together on the final page, starting a new page when their reserved block will not fit;
- embed Unicode fonts that render `£` and non-ASCII organisation/party names;
- add `Page N of M` in a second pass after the final page count is known.

If that proof fails any item, replace the renderer before fixing the template format around it.

The function will:

1. Require the existing authenticated server-function middleware and use its user-scoped Supabase client for all authorisation calls.
2. Call only narrow public database routines that derive the caller, organisation, permissions, and source invoice server-side.
3. For preview, require both `document.template.manage` **and the source invoice's existing read permission**, then read the selected draft and real invoice contract, apply organisation terminology, and render a watermarked PDF without consuming an issue number.
4. For issue/amend, reserve the next permanent sequence, receive the frozen contract and exact template version, render the PDF, calculate SHA-256 over the actual bytes, upload to the private document-output bucket, then complete the issue record.
5. Apply the pre-send/post-send amendment rules above through named authorising database routines.
6. For reprint, authorise `document.reprint`, read the existing stored object only, verify its checksum, return a short-lived signed URL, and never invoke the renderer.
7. Record issue and reprint events through the existing append-only event/audit infrastructure, including actor, invoice, issue, sequence, template version, checksum, and replacement relationship.

Create the private `document-output` bucket through the native Storage API, with PDF-only uploads, a size limit, tenant-prefixed object paths and no public URL. Browser code never receives bucket write access; the server function uploads only after the database authorises the action, and returns short-lived signed read URLs.

Preview objects have their own organisation-scoped ledger row with `expires_at`: previews expire after 15 minutes, signed URLs after 5 minutes, and an idempotent cleanup routine deletes expired objects and rows. Cleanup runs on every output request and through the existing scheduled dispatch path, so abandoned previews are removed even when nobody returns to the screen. Permanent issued objects are excluded from that policy.

The organisation logo continues to come from the existing `brand.logo.url` terminology/branding resource. The renderer fetches it server-side over HTTPS with MIME and size validation, embeds the image bytes into the PDF, and stores its source URL plus SHA-256 in the frozen contract. Missing or invalid logos fall back to the existing text wordmark; the issued PDF bytes and contract remain explainable if the logo later changes.

## PR 3 — Extend “Output and printing” without adding navigation

Reshape the existing `/operations/output` screen so the document area is clear while preserving its current printer/channel capabilities:

- Add a sales-invoice row showing the active template version, latest draft, and readiness state.
- Add a permission-gated full-page **Upload draft** form over the desk. It accepts the existing JSON block-template format, validates it before saving, and explains the format in a folded technical section.
- Add **Preview with invoice**, using a real sales-invoice picker and the rendering function’s signed preview URL.
- Add **Promote to active**, with a small confirmation and automatic supersession of the prior active version.
- Show issued sales invoices with sequence, source invoice, template version, issuer/time, checksum, replacement link, and **Reprint exact issued PDF**.
- Add Issue/Amend controls to the existing invoice record page. Before send, the screen describes the void-and-reissue result; after send, amendment is disabled and links to the credit-note action.
- Keep empty states actionable: no invoice links to Sales, missing company details links to Organisation, and no template explains that a draft must be uploaded here.
- Keep plain-language summaries visible and place checksums, storage paths, and raw contract details behind a “Technical detail” toggle.

## 5. Structural and behavioural proof

Add database assertions, included in the existing CI catalogue, proving:

- all new organisation-scoped tables are registered, forced through RLS, audited, and inaccessible across organisations;
- only one active sales-invoice template exists per organisation/document type;
- sequence prefixes cannot change after use, numbers increase monotonically, and failed numbers are not reused;
- issuing requires `document.issue`, template actions require `document.template.manage`, and reprint requires `document.reprint`;
- the sales-invoice contract contains every declared section and applies terminology overrides;
- the frozen contract retains the original party, address, legal, terminology and logo-provenance values after source edits and a partner merge;
- VAT-registered invoices refuse each missing legal field with the expected destination;
- pre-send amendment voids the original, creates a newly numbered replacement and never reuses the old number;
- post-send amendment is refused with a credit-note destination;
- reprint returns the original stored object/checksum and does not render or allocate another number;
- issue and reprint produce audit/event records.

Add focused TypeScript tests for request validation, rendering helpers, checksum behaviour, and friendly refusals. Add an authenticated end-to-end sales-invoice test covering draft upload, real-record preview, activation, issue, amendment, signed download, and exact-byte reprint.

Finish each PR with the applicable repository checks. The final PR runs typecheck, lint, unit tests, build, schema/CI assertions against a fresh database, an authenticated browser pass of both updated screens, and visual PDF QA on the normal, 200-line, Unicode and amendment fixtures.

## Technical assumptions

- “Upload a template” means uploading the existing JSON block-template format; DOCX/Word template parsing is outside this one-type infrastructure proof.
- Adding the pinned Worker-compatible `pdf-lib` and `@pdf-lib/fontkit` packages plus bundled Noto Sans font assets is part of PR 2; no browser, operating-system font or native binary is used at runtime.
- The existing output request/render/delivery tables remain for general output routing. `document_issue` becomes the legal issuance ledger and points to the private stored artefact.
- The private bucket is infrastructure, not a public content surface. Signed URLs are short-lived and created only after a fresh permission check.
- Sales invoice is the only enabled document contract in this change. Other document types remain listed as unsupported or unchanged, and label printing is untouched.
