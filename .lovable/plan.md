# Sales invoice document output pipeline

## Goal

Build one production-shaped document path for **sales invoices** only: manage a versioned template, preview it against a real invoice, issue an immutable numbered PDF into private storage, and retrieve the exact issued bytes for reprint.

This extends the existing Output and printing screen and reuses the current output-template, terminology, permission, audit, document-lineage, and generated row-security architecture. It does not add label printing or another document type.

## 1. Extend the existing governed output model

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
- Add `erp.document_issue`, scoped by organisation, recording the source invoice, exact template/version, issuer/time, storage object path, checksum, sequence number, status, and optional `replaces_issue_id`.
- Preserve failed sequence reservations as failed/void issue attempts rather than recycling their numbers. Protect issued rows and sequence identity fields from later mutation.
- Register every new table in `erp_meta.table_policy`, regenerate row security, attribution, audit, and append-only protections where applicable, and keep organisation identity derived by `erp.require_tenant_id()` rather than accepted as input.

## 2. Declare and validate the sales-invoice contract

Add an explicit database contract routine for `sales_invoice` containing:

- header: issued number, document number, dates including tax point, currency, references, and replacement link;
- issuing company: legal name, company registration number, VAT registration number, and registered office;
- customer: legal/trading name, tax identifier where present, and the frozen invoice address snapshot;
- lines: product/code, description, quantity, unit, unit price, discount, net, VAT code/rate, VAT, and gross;
- tax summary: grouped VAT rate/net/VAT totals;
- totals: net, VAT, gross, and total VAT in sterling.

Add the missing structured company setup needed by that contract: a registered-office address and an explicit tax-point value or deterministic tax-point derivation captured on the invoice. Use the existing entity tax-registration table for VAT registration status/number.

Before reserving an issue number, validate the invoice type and required data. For a VAT-registered issuing company, refuse the issue when any required legal field is absent. Each refusal identifies the exact missing field and supplies the appropriate existing destination:

- company/VAT/registered-office problems → Organisation and approval routing;
- tax point or line tax data → the invoice record;
- missing customer/address data → Business partners.

Register these refusals in the existing refusal/resource layer so the UI shows plain language and retains technical detail behind its existing disclosure.

## 3. Add the authenticated rendering function and private archive

Add a declared `document-output` Edge Function following the repository’s existing Deno/config conventions.

The function will:

1. Require and validate the caller’s Supabase bearer token.
2. Call only narrow public database routines that derive the caller, organisation, permissions, and source invoice server-side.
3. For preview, read the selected draft and real invoice contract, apply organisation terminology, render a watermarked PDF without consuming an issue number, store it under a short-lived preview path, and return a signed URL.
4. For issue/amend, reserve the next permanent sequence, receive the frozen contract and exact template version, render the PDF, calculate SHA-256 over the actual bytes, upload to the private document-output bucket, then complete the issue record.
5. For amendment, require the prior issue, allocate a new number, set `replaces_issue_id`, and show the replacement reference in the PDF.
6. For reprint, authorise `document.reprint`, read the existing stored object only, verify its checksum, return a short-lived signed URL, and never invoke the renderer.
7. Record issue and reprint events through the existing append-only event/audit infrastructure, including actor, invoice, issue, sequence, template version, checksum, and replacement relationship.

Use a private bucket with tenant-prefixed object paths, restrictive Storage policies, PDF-only uploads, and no public URL. Bucket provisioning will use the supported Supabase Storage mechanism; schema/policy changes remain forward-only and deployment-safe.

## 4. Extend “Output and printing” without adding navigation

Reshape the existing `/operations/output` screen so the document area is clear while preserving its current printer/channel capabilities:

- Add a sales-invoice row showing the active template version, latest draft, and readiness state.
- Add a permission-gated full-page **Upload draft** form over the desk. It accepts the existing JSON block-template format, validates it before saving, and explains the format in a folded technical section.
- Add **Preview with invoice**, using a real sales-invoice picker and the rendering function’s signed preview URL.
- Add **Promote to active**, with a small confirmation and automatic supersession of the prior active version.
- Show issued sales invoices with sequence, source invoice, template version, issuer/time, checksum, replacement link, and **Reprint exact issued PDF**.
- Add Issue/Amend controls to the existing invoice record page so the action starts where users inspect the invoice.
- Keep empty states actionable: no invoice links to Sales, missing company details links to Organisation, and no template explains that a draft must be uploaded here.
- Keep plain-language summaries visible and place checksums, storage paths, and raw contract details behind a “Technical detail” toggle.

## 5. Structural and behavioural proof

Add database assertions, included in the existing CI catalogue, proving:

- all new organisation-scoped tables are registered, forced through RLS, audited, and inaccessible across organisations;
- only one active sales-invoice template exists per organisation/document type;
- sequence prefixes cannot change after use, numbers increase monotonically, and failed numbers are not reused;
- issuing requires `document.issue`, template actions require `document.template.manage`, and reprint requires `document.reprint`;
- the sales-invoice contract contains every declared section and applies terminology overrides;
- VAT-registered invoices refuse each missing legal field with the expected destination;
- amendment creates a new issue and sequence linked to the replaced issue;
- reprint returns the original stored object/checksum and does not render or allocate another number;
- issue and reprint produce audit/event records.

Add focused TypeScript tests for request validation, rendering helpers, checksum behaviour, and friendly refusals. Add an authenticated end-to-end sales-invoice test covering draft upload, real-record preview, activation, issue, amendment, signed download, and exact-byte reprint.

Finish with the repository’s required checks: typecheck, lint, unit tests, build, Deno checks for all Edge Functions, schema/CI assertions against a fresh database, and an authenticated browser pass of the two updated screens.

## Technical assumptions

- “Upload a template” means uploading the existing JSON block-template format; DOCX/Word template parsing is outside this one-type infrastructure proof.
- PDF rendering will use a pinned Deno-compatible, pure JavaScript renderer inside the Edge Function; no browser or native binary dependency.
- The existing output request/render/delivery tables remain for general output routing. `document_issue` becomes the legal issuance ledger and points to the private stored artefact.
- The private bucket is infrastructure, not a public content surface. Signed URLs are short-lived and created only after a fresh permission check.
- Sales invoice is the only enabled document contract in this change. Other document types remain listed as unsupported or unchanged, and label printing is untouched.
