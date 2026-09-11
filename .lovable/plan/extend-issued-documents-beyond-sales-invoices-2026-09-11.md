# Extend issued documents beyond sales invoices

## Important prerequisite

The repository currently contains the older template renderer, but the approved sales-invoice issue pipeline is still pending: the sequence, immutable issue ledger, PDF archive, exact-byte reprint and issue screens are not present. Complete those approved three PRs first, then extend the same infrastructure below. Do not create competing template, issue, sequence, preview or storage infrastructure.

The requested delivery output will be implemented as **two separate issued documents**: Delivery note and Packing list. This makes five independently issued output types in total.

## 1. Extend schema, contracts and assertions

- Reuse the existing document template/version, document sequence, document issue and preview structures established by the sales-invoice pipeline.
- Register five output types, each with its own permission and independent organisation-scoped sequence:
  - credit note;
  - delivery note;
  - packing list;
  - purchase order;
  - goods received note.
- Grant each permission to the existing composable roles that already own the corresponding source-document action. Do not broaden unrelated access.
- Declare one versioned, typed contract builder per output type. Every issued contract freezes resolved names, addresses, terminology, lines, quantities, references, totals where relevant, logo provenance and source/replacement relationships so later source edits cannot change its meaning.
- Keep tenant identity database-derived, route every issue/reprint through named authorising routines, and write issue/reprint audit events.
- Add structural assertions for every contract, permission, sequence isolation, RLS policy, authorising door and immutable issue. Assert that each output type consumes only its own monotonic sequence.

## 2. Explicit contracts

- **Credit note:** credit number/date/tax point/currency/reason; original invoice and replacement references; issuing company legal/VAT/registered-office snapshot; customer and credit address; credited lines with quantity, unit price, discount, net and VAT; tax summary; net/VAT/gross totals and sterling VAT total.
- **Delivery note:** delivery number/date; sales order/customer references; sender, ship-to and delivery address; carrier/service/consignment details; delivered lines with product/code/description/unit/quantity, batch/serial and expiry where present; package count and delivery instructions. No prices.
- **Packing list:** packing-list number/date; delivery/sales-order/customer references; sender and ship-to snapshots; packages, dimensions/weight where recorded, package contents, product/code/description/unit/quantity, batch/serial and expiry where present. No prices.
- **Purchase order:** order number/date/currency/status; buyer legal, delivery and invoice addresses; supplier identity/address/tax details; requester/buyer and supplier references; requested/promised delivery dates; lines with product/code/description/unit/quantity/unit price/discount/net/tax; tax summary, charges and totals; payment and delivery terms.
- **Goods received note:** GRN number/date; purchase-order/supplier/delivery references; receiving site and goods-in location; receiver; received lines with ordered/received/accepted/rejected quantities, unit, batch/serial, manufacture/expiry dates and quality/status details; discrepancies and notes. No commercial prices unless already required by the existing receiving record.

Missing source data must produce a named, plain-language refusal that identifies the field and links to the existing screen where it can be supplied.

## 3. Reuse rendering and archive behavior

- Feed all five contracts into the existing server-side PDF renderer, embedded fonts, organisation logo handling, terminology resolution, private bucket and short-lived signed URL flow.
- Issue once into the immutable archive; reprint retrieves and checksum-verifies the exact original bytes without rendering again.
- Apply the same preview expiry/deletion policy and require both template-management permission and source-record read permission for previews.
- Keep document-specific presentation rules in templates: pagination preserves complete rows and keeps summaries/totals together where applicable; all files include `Page N of M`.

## 4. Add actions to existing record screens

- Add the existing verb-pattern actions to the selected record on its current generic document screen; add no route or navigation item.
- Credit note: **Issue credit note** and **Reprint credit note**.
- Delivery: **Issue delivery note**, **Issue packing list**, and the corresponding reprint actions.
- Purchase order: **Issue purchase order** and **Reprint purchase order**.
- Goods receipt: **Issue goods received note** and **Reprint goods received note**.
- Use the existing full-page action presentation for preview/issue details and compact confirmation for the final issue action. Disable repeat issue verbs when lifecycle rules forbid them, while leaving exact-byte reprint available to authorised users.

## 5. Verification and delivery order

Deliver after the sales-invoice prerequisite in three reviewable batches matching the established architecture:

1. Contracts, permissions, sequences, authorising routines and structural assertions.
2. Renderer mappings, private archive handling and fixtures covering long multi-page documents, Unicode and exact-byte reprint.
3. Existing-record-screen actions and focused interaction tests.

Run the repository's typecheck, lint, tests, build and schema assertion catalogue after each batch. Production database changes continue only through the repository deployment workflow.