# Add Peppol-ready electronic invoice payloads

## Scope and dependency

Extend the approved document issue pipeline for **sales invoices and credit notes only**. Each issue produces both a PDF and a structured UBL 2.1 XML representation. This adds no sending, access-point connection, participant registration, directory lookup or delivery status.

The shared `document_issue` pipeline remains a prerequisite and the sole issue record. Do not introduce a second issue ledger, sequence, template system or navigation area.

## 1. Extend the immutable issue record

- Add electronic representation metadata to the same organisation-scoped issue row: UBL object path, media type, profile identifier, customization identifier, byte size, SHA-256 checksum, validation status, validation time and validator/ruleset version.
- Keep the PDF and XML checksums independent and immutable. An issue is complete only when both required representations have been archived successfully.
- Freeze the same resolved business contract used by the PDF before either representation is generated. Both files therefore describe the same issue number, parties, lines, tax and totals.
- Store permanent XML under the issue's existing tenant-prefixed private archive path. Return only short-lived signed download URLs.
- Extend append-only protections, RLS registrations, audit events and structural assertions to cover the electronic representation fields.

## 2. Declare the UBL mappings

Create typed, explicit mappings from the frozen contract to:

- UBL 2.1 `Invoice` for sales invoices;
- UBL 2.1 `CreditNote` for credit notes.

The mapping will include the Peppol BIS Billing profile/customization identifiers, invoice/credit-note type code, issue date, due date where applicable, currency, buyer reference or order reference, seller and buyer identifiers/electronic endpoints with scheme identifiers, legal and postal addresses, VAT identifiers, payment means and account details, payment terms, line identifiers and quantities with UNECE unit codes, item names/descriptions/identifiers, prices, allowances/charges, VAT category/rate/exemption reason, tax subtotals, totals, preceding-invoice reference for credit notes and the payable/credit amount.

Add structured organisation and customer settings only where the existing model cannot represent mandatory Peppol concepts, notably electronic endpoint identifier plus scheme and payment-account details. Tenant scope is database-derived and every change uses existing organisation/business-partner settings screens rather than new navigation.

## 3. Generate and validate server-side

- Generate canonical UTF-8 XML server-side from the frozen contract with deterministic element ordering and XML escaping. Never generate XML in the browser.
- Validate before committing the issue against:
  1. Clove's typed UBL 2.1 structure and cardinality checks before serialization;
  2. the official EN 16931 Schematron rules;
  3. the official Peppol BIS Billing 3.0 Schematron rules for the pinned release.
- Use `saxon-js` to execute build-time-compiled Schematron SEF packages in the edge runtime. Pin and bundle the official CEN and OpenPeppol artefacts; do not fetch changing rules at issue time. Record the exact ruleset versions on each issue so validation remains explainable after upgrades.
- Treat official Schematron errors as blocking and warnings as visible non-blocking findings. The controlled serializer provides only the UBL structures it declares; validation is not delegated to an external service.
- Translate validation findings into stable Clove refusal codes and plain-language messages naming the field, affected invoice line when relevant, and the existing screen that fixes it. Keep rule IDs and XML paths behind the existing technical-detail disclosure.
- Do not consume or finalize an issue number when preflight validation fails. If archive completion fails after reservation, retain the number as failed/void according to the existing no-reuse rule.

## 4. Download from the existing document detail panel

- Add **Download electronic invoice** beside the existing PDF issue/reprint controls on the selected sales invoice or credit-note record.
- The action requires the existing source-record read permission plus document reprint/download authority, calls an authenticated server function, verifies the archived XML checksum, audits the download, and returns a short-lived signed URL.
- Show the electronic format, validation result and issue time in plain language. Fold profile IDs, ruleset version, checksum, byte size and raw validation details behind the existing technical-detail toggle.
- When no issue exists, explain that the invoice or credit note must first be issued. When XML generation failed, show the actionable validation errors rather than a generic download failure.
- Add no route and no navigation item.

## 5. Assertions and verification

- Assert one issue holds the PDF and UBL representation for the same frozen contract and sequence number.
- Assert invoice and credit-note roots, namespaces, profile/customization identifiers and source-document type mapping.
- Assert required Peppol failures are refused before completion and surfaced through registered plain-language resources.
- Assert XML checksum immutability, tenant isolation, exact-byte retrieval and audit events.
- Add representative valid invoice and credit-note fixtures plus failures for missing endpoint schemes, VAT identifiers, address/country data, line units, tax categories, payment data and preceding-invoice reference.
- Run the pinned EN 16931/Peppol Schematron fixtures, typed UBL serializer fixtures, schema assertion catalogue, typecheck, lint, tests and build.

## Delivery order

Fold this into the existing three-PR document-pipeline sequence:

1. Schema additions, frozen UBL mappings, permissions/refusals and structural assertions.
2. XML generator, pinned validator artefacts, private storage and checksum-verifying download server function alongside the PDF renderer.
3. Existing document-detail-panel status and download action.

Production database changes continue only through the repository deployment workflow.