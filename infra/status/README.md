# The status page

Specification v1.6 §16.5 (v1.2 §17.4): a status page states current and
historical availability, maintained by the platform, not by inference.

This is a Cloudflare Worker with one KV namespace. It stores what the product
sends it and serves it as a page and as JSON. It never reads the product's
database — a page served from the product's own Postgres goes dark exactly
when somebody needs it, which is why the earlier decision kept the page
outside; this is the same decision, with the page now existing.

## How it is fed

The product publishes through its own integration gateway. In the platform's
own organisation (`erp.designate_platform_organisation`), register an external
system on adapter `status_page@1`:

- `base_url`: `https://<worker host>/publish`
- `credential_ref`: `env://CLOVEERP_STATUS_TOKEN` — the dispatch worker
  resolves it from its environment and sends it as `Authorization: Bearer`
- enable the operation `status.publish`

Every declaration and every update then becomes one `status.publish` command
(`erp.communicate_incidents()`, run by the platform sweep), delivered by the
dispatch worker with an idempotency key. The page answers a repeated key with
200 and stores nothing twice. `erp_meta.incident_publication` records which
command carried which update to which page; the console shows it.

## Deploying

```
cd infra/status
wrangler kv namespace create STATUS       # put the id in wrangler.toml
wrangler secret put STATUS_PUBLISH_TOKEN  # the same value the worker holds as CLOVEERP_STATUS_TOKEN
wrangler deploy
```

Point `status.<your domain>` at the worker. The token is never stored in the
product: the external system's `connection` holds the URL only, and
`erp.gateway_integrity_report()` fails a stored credential.

## What it shows

- Current incidents with severity, state, components, origin (a provider
  below the platform, when that is where it started), scope and the time of
  the next promised update.
- Every update as posted — the five fields rendered once by the product, the
  same text the organisations were emailed and shown in the application.
- Resolved incidents for the last ninety days. The product keeps the record
  for as long as it holds it (D36); this page is the public view.
