# Versioned REST API and outbound webhooks

## Outcome

Expose a deliberately allow-listed subset of Clove ERP’s existing `public.erp_*` doors at `/api/public/v1/*`, authenticated by organisation API keys. Add organisation-owned outbound webhook subscriptions and delivery history. Extend the existing **Integrations** screen under **Connections and automation**, and publish generated reference documentation for exactly the routes that are exposed.

This adds no new ERP business operations. REST handlers authenticate, validate, establish database context and call existing doors.

## 1. API identity, keys and scopes

- Add organisation-scoped API-key records linked to an existing `kind = 'service'` principal.
- Store only a lookup prefix and a cryptographic hash. Generate a high-entropy key server-side and return the plaintext once; never make it readable again.
- Add named authorising routines to create, list and revoke keys, and to update `last_used_at` after successful authentication.
- Store requested scopes as existing permission codes. Creation refuses any scope the service principal does not currently receive through principal → grant → role → permission.
- Re-evaluate the principal’s effective permission on every API call. A later role/grant removal therefore takes effect immediately even if the key’s recorded scope still contains the code.
- Keep tenant identity server-derived from the authenticated key. No REST body or query parameter may select or override an organisation.
- Attribute each call to the linked service principal before invoking the existing door, so existing authorisation decisions, row attribution and audit coverage retain the true caller.

## 2. Versioned REST exposure

- Add explicit `/api/public/v1/...` TanStack server routes. This prefix is externally reachable, so each handler performs API-key authentication itself before reading or writing.
- Maintain one declarative API v1 catalogue mapping HTTP method, stable path, existing `public.erp_*` door, required existing permission code, input schema, response schema and documentation text.
- Expose only catalogue entries; do not provide a generic arbitrary-RPC endpoint.
- Use plain JSON envelopes and consistent status/error mappings. Database refusal codes remain authoritative but are translated into safe, plain-language API errors.
- Require `Idempotency-Key` on every POST/PATCH/DELETE. Persist organisation, key/principal, endpoint, request fingerprint, status and the original response. An exact replay returns the stored response; reusing a key with a different request returns conflict.
- Put bounds on all input and pagination. Never return secrets, internal schemas or cross-tenant identifiers.

## 3. Outbound webhook subscriptions

- Add organisation-scoped subscriptions with event type, target HTTPS URL, signing-secret reference, status and timestamps. Event types come from the existing versioned event catalogue.
- Generate the signing secret server-side, show it once, and store only encrypted/restricted secret material needed by the worker. It is never returned by list/read functions or written to logs.
- Fan eligible existing `erp.event` rows into a webhook delivery queue. Keep event payload/version and subscription identity frozen per delivery.
- Extend the current worker claim/deliver/complete/fail model rather than adding a second delivery engine.
- Sign the exact request bytes with HMAC-SHA256. Send an event id, delivery id, timestamp, event type/version, idempotency key and signature headers.
- Retain database-owned retry/backoff, lease recovery and permanent-failure classification. Record every attempt’s time, result, bounded response status/body and next retry without recording the secret.
- Add named authorising routines to create, disable, rotate-secret and list subscriptions; list deliveries; and replay a failed delivery. Replay creates a linked new attempt and preserves the original evidence.

## 4. Existing Integrations screen

- Extend `/operations/integrations`; add no navigation destination.
- Organise it into clear views for **API keys**, **Webhook subscriptions**, **Delivery log**, and the existing gateway health/backlog.
- Use full-page forms over the desk for key creation and webhook setup; use compact confirmations for revoke, disable and replay.
- Show a newly created API key or signing secret once with copy/download controls and an explicit “cannot be shown again” state.
- Show scopes using friendly permission names, service-principal ownership, last use, revocation, endpoint status, event type, retry state and response summary. Keep request/response technical detail folded behind a toggle.
- Empty states explain which permission or setup is missing and link to the existing role/service-principal setup where appropriate.

## 5. Generated API reference

- Generate an OpenAPI 3.1 document from the same v1 catalogue used by the handlers, preventing documentation drift.
- Publish human-readable reference pages within the existing application shell, including authentication, idempotency, pagination, errors, webhook verification and per-door request/response examples.
- Publish the machine-readable specification at `/api/public/v1/openapi.json` without exposing private data or callable doors outside the allow-list.
- Version paths and schemas as v1. Breaking changes require a new version; additive fields remain compatible.

## 6. Database governance and proof

- Use new forward-only migrations only. Every new table is organisation-scoped, receives generated RLS, tenant-freeze, attribution and audit coverage, explicit grants, and the standard end-of-migration generator/assertion block.
- Every state change goes through a named `erp.*` authorising routine and a governed `public.erp_*` wrapper. Register UI-only/API-only doors and refusal codes using existing catalogues.
- Add structural assertions proving:
  - an API key cannot be created with a permission absent from its service principal;
  - removing the principal’s grant immediately removes API access;
  - a key authenticated for one organisation cannot establish or read another organisation’s context;
  - plaintext keys and signing secrets are not stored or returned;
  - every write requires idempotency and exact replay returns the original response;
  - webhook signatures cover the exact bytes and timestamp;
  - retries, terminal failures and manual replay preserve evidence and tenant isolation;
  - every exposed v1 route maps to a real governed public door and appears in the generated OpenAPI document.
- Extend existing grant, door-isolation, refusal, public-surface, attribution and audit suites rather than relying on manual role testing.

## Technical delivery order

1. **Schema and assertions:** API-key/scopes/idempotency/subscription/delivery structures, authorising routines, permissions, policies and CI proofs.
2. **API and worker:** v1 catalogue, authenticated handlers, audit context, exact response replay, HMAC delivery and retries.
3. **Integrations and documentation:** management views/forms, one-time credentials, delivery detail/replay and generated OpenAPI/reference pages.
4. Run typecheck, lint, tests and build; run local schema checks when the database environment is available. Production migrations continue exclusively through the repository deployment workflow.