# The dispatch worker

The one component that must live outside the database.

B8 and B9 are built so the database holds no credentials: `erp.external_system`
stores a `credential_ref` — a pointer into a secret store — and
`erp_ref.looks_like_secret()` refuses to let an actual secret be written there.
That is only worth anything if something outside resolves those references, and
this is that something.

## What it is allowed to do

Nothing that is not already a claimed row. The whole vocabulary:

| Concern    | Claim                      | Finish                                                   |
|------------|----------------------------|----------------------------------------------------------|
| Scheduler  | `erp.claim_job_runs`       | `erp.complete_job_run` / `erp.fail_job_run`               |
| Outbox     | `erp.claim_message_batch`  | `erp.complete_message` / `erp.fail_message`               |
| Commands   | `erp.claim_command_batch`  | `erp.complete_command` / `erp.fail_command` / `release_command` |

Plus two reclaimers for work whose lease expired because a worker died holding
it: `erp.reclaim_timed_out_runs` and `erp.reclaim_expired_commands`.

The database decides what is due, what may overlap, how many may run at once,
what a failure costs and when the next attempt happens. The worker decides
nothing — it does the work and reports back. That split is why a bug here
cannot corrupt the schedule.

## Why a direct Postgres connection and not the REST API

`erp.*` is deliberately not exposed to PostgREST, and these functions are not
on the curated `public.erp_*` surface either — that surface is for the user
interface, and a worker is not a user. More importantly
`erp.set_job_principal()` requires a session whose role bypasses RLS, which is
what `erp.session_is_trusted()` checks. So the worker connects as a trusted
role and asserts a service principal per transaction.

## Identity

Every unit of work runs inside one transaction that begins by calling
`erp.set_job_principal(<service principal>)`. That sets a transaction-local
GUC, never a session one: a pooled connection must not carry a tenant context
to whoever is served next. B1 has an assertion for exactly that mistake.

The principal must be `kind = 'service'`. `set_job_principal()` refuses to
adopt a person, so a worker cannot act as somebody.

## Running it

Two entrypoints over one core.

    bun run worker/src/main.ts        # long-lived loop
    supabase/functions/dispatch       # Edge Function, driven by a cron

Configuration, all from the environment and none of it from the database:

    CLOVEERP_DATABASE_URL   a connection string for a role that bypasses RLS
    CLOVEERP_TENANTS        comma-separated tenant ids to serve
    CLOVEERP_PRINCIPALS     matching service principal ids, same order
    CLOVEERP_SYSTEMS        comma-separated external system codes to drain
    CLOVEERP_POLL_MS        loop interval for the long-lived entrypoint (default 5000)
    CLOVEERP_WORKER_NAME    the name a claim is recorded under (default clove-erp-worker-<pid>)
    RESEND_API_KEY          the send credential for the email handler
    <REF>                   the value a credential_ref names — see below

These were `ERPWARE_*` until 20260904980000 renamed the product's prefix. There
is no compatibility shim: `required()` throws by name, so a half-done rename
stops the worker rather than degrading it quietly.

A `credential_ref` is a URI and only `env://` is implemented. The name after
the scheme is read from the environment **exactly as written** — `env://SMTP_PW`
reads `SMTP_PW`, with no prefix of any kind. This file said `ERPWARE_SECRET_<REF>`
for months, which no code has ever read.

A credential is read here and used here. It is never written back.
