# clove-erp-mcp — the CloveERP MCP connector

A **separate** Cloudflare Worker (not the nitro-built `clove-erp` app Worker)
that lets an assistant operate CloveERP over the Model Context Protocol, as an
OAuth-secured remote connector. Built per the approved plan
(`sharded-sniffing-lemon.md`) and the HMRC-compliance decisions
(`memory/mcp-connector-build.md`).

> **Status: WIP scaffold (Stage 1).** The code is written against the real
> installed library types and is meant to typecheck, but the OAuth flow and the
> Supabase bridge can only be *proved* once the Worker is deployed with its
> Cloudflare + Supabase configuration (below). Nothing here is deployed yet.

## Shape

- **Transport/auth:** Cloudflare's `@cloudflare/workers-oauth-provider` makes
  this Worker an OAuth 2.1 provider; `createMcpHandler` (from `agents/mcp/server`)
  serves the MCP endpoint over Streamable HTTP. The MCP tools receive the
  authenticated user via `getMcpAuthContext()` (the `props` stored at
  authorization).
- **Identity:** bridged to **Supabase Auth** — a user signs in with their
  existing CloveERP account on our `/authorize` consent page; we authenticate
  against Supabase, then `completeAuthorization(...)` stores the Supabase session
  in the (encrypted) `props`. Tokens refresh via `tokenExchangeCallback`.
- **Acting as the user:** each tool builds a Supabase client from the user's
  access token and calls the existing `public.erp_*` doors. The database's
  permission + tenant guards therefore apply unchanged — the connector can do
  nothing the user cannot.

## Tools

**Stage 1 (here, read/prepare only — no HMRC-rule risk):**
- `vat_obligations` → `public.erp_vat_obligations`
- `vat_boxes` → `public.erp_vat_boxes`
- `vat_return_export` → `public.erp_vat_return_export` (the MTD body)

**Stage 2 (NOT built here; post HMRC production approval):** a `submit` tool that
only confirms a return a human already finalised and declared in the app, with
its own fraud-prevention-headers connection method. See
`memory/mcp-connector-build.md`.

## Deploy prerequisites (the owner's, at deploy time — not blockers to building)

- A **KV namespace** bound as `OAUTH_KV` (grants/tokens store).
- Worker **vars**: `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` (public anon key —
  used only to sign the user in; the connector never holds the service role key).
- A **reserved subdomain/route** for the connector (e.g. `mcp.cloveerp.com`),
  which also needs the route reserved in the DB + the e2e inventory
  (`memory/adding-a-public-route.md`).
- A **deploy workflow** for this separate Worker (it is not shipped by
  `app.yml`).
- Compatibility flags: `nodejs_compat`, and `global_fetch_strictly_public` if
  Client-ID-Metadata-Documents are enabled.
- Its own **security review** (a new public auth surface).

## Not done / to verify before it is trusted

- Live OAuth round-trip (DCR / consent / token) and the Supabase sign-in bridge.
- The exact `createMcpHandler` server-factory wiring against a running Worker.
- Whether a confirm step is wanted before `vat_return_export` (reads only today).
