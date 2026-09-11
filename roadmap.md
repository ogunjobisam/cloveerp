# Roadmap

- [ ] Build record document with screenshots
- [ ] Set a password on ogunjobisam@gmail.com so sign-in works with either Google or password
- [ ] Use that account to capture in-app screenshots for the document
- [ ] PR 1: sales-invoice output schema, frozen contract and assertions
- [ ] PR 2: authenticated PDF rendering, private archive and exact-byte reprint
- [ ] PR 3: Output and printing plus invoice issue screens
- [ ] Extend document output with separate credit note, delivery note, packing list, purchase order and goods received note contracts, permissions, sequences, assertions and record-screen actions
- [ ] Add immutable UBL 2.1 / Peppol BIS Billing 3.0 payloads for sales invoices and credit notes, offline validation and detail-panel download
- [ ] Expose an allow-listed v1 REST API over existing public ERP doors with service-principal API keys, scope enforcement, audit attribution and idempotent writes
- [ ] Add organisation webhook subscriptions, HMAC-signed event delivery, retry history and customer replay controls
- [ ] Extend Integrations with API key, webhook and delivery management, and publish generated v1 API reference documentation
- [ ] Migration 20260911074500_public_api_keys_and_webhooks.sql is now in supabase/migrations/ — awaiting the deploy workflow run on push
