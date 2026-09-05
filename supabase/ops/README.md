# Operations

One-off scripts that repair a specific database. Nothing here is part of the
product's definition, and nothing here runs in CI.

The distinction matters. `supabase/migrations/` is the sequence that builds
Clove ERP from nothing, and CI proves on every push that it still does. A script
in this directory is the opposite: it exists because one particular database
drifted from that sequence, and it is written against the state that database
actually reached rather than the state the repository describes.

A file here has done its job once it has been applied. It is kept because the
repair should be reviewable and reproducible, not because it will be needed
again.

**The refusal codes in these files are the retired ones.** 20260904980000 moved
every refusal from `ERPWARE_` to `CLOVEERP_`; these scripts are dated records of
what was actually run on a given day and have not been rewritten, because a
record that has been edited to look current is no longer a record. Do not copy a
raise out of one. Replaying a script from here would put the old prefix back into
the routines it touches, and `erp.assert_no_legacy_refusal_prefix()` would fail
the next build — which is the guard working, not a false alarm.

---

## How live is reached from 6 September 2026

Nothing in this directory is the route to production any more. Two workflows
are:

- `.github/workflows/deploy.yml` — on every push to `main`, applies the
  repository's pending migrations to the live project by replay
  (`supabase db push --include-all`), then runs `erp.platform_assurance()` and
  `erp.assert_whole_database_reconciles()` over the same connection and fails
  if either is not green. On every pull request it prints what would apply.
- `.github/workflows/restore_drill.yml` — quarterly and on demand, dumps the
  product schemas from live, restores them into a fresh PostgreSQL of the
  live major version on the runner, and runs the same two checks against the
  restored data. D28.

Both read one repository secret, `CLOVEERP_LIVE_DATABASE_URL`: the project's
session-pooler connection string (the direct host is IPv6-only and a runner
cannot reach it), percent-encoded. It is set by the project owner and read by
nobody else; no connection string is stored anywhere in this repository or in
the environment the work is done from, and none should be.

**Before the first replay**, the live history table has to learn which
repository migrations it already carries: every change up to and including
`20260905040000` reached live through the Supabase MCP connector, which
recorded its own names rather than the repository's filenames. Run `deploy`
by hand once with `mark_applied = true`, on a commit whose migrations are all
already on live (the merge of PR #59, `edbd793`, or any later commit whose
new migrations have been applied by hand). Every repository version is then
recorded as applied and replay starts from the next one. Running it twice is
harmless; running it on a commit with an unapplied migration would record that
migration as applied without applying it, which is the one way to misuse it.

The connector remains available for reading and for an emergency; it is no
longer how a change lands.

---

## 20260831_live_reconciliation.sql

Brings the production project (`xpzffnnhnhcqyjqcueja`) to the schema `main`
describes.

### Why a script rather than the migrations

Production has 139 migrations applied, newest `20260830134027`. It has every
migration the Lovable integration wrote and none of the eight written in the
session that produced pull requests #20 to #22. Five of those eight are
numbered *earlier* than work already applied there, so the repository's filename
order and production's history disagree.

Replaying the eight in filename order was tried against a local copy of
production's state. All eight fail and none applies:

```
20260829330000  ERPWARE_PUBLIC_API_UNSAFE: 112 finding(s)
20260829340000  ERPWARE_PUBLIC_API_UNSAFE: 114 finding(s)
20260829350000  ERPWARE_PUBLIC_API_UNSAFE: 112 finding(s)
20260829360000  column bt.create_permission does not exist
20260829370000  ERPWARE_PUBLIC_API_UNSAFE: 112 finding(s)
20260830140000  function erp.create_party(...) does not exist
20260830150000  function public.erp_create_party_with_roles(...) does not exist
20260831130000  column bt.create_permission does not exist
```

The cause is structural rather than accidental. Each of the August 29
migrations ends by calling `erp.assert_public_api_safe()`, which on that
database is still the blanket ban on public `SECURITY DEFINER`; the
platform-owner layer added later violates it 27 times. The migration that turns
that ban into a registered one is `20260830140000`, which sorts *after* them and
then fails itself because the migration it depends on has rolled back. Every
migration is atomic, so each failure leaves nothing behind and the next fails on
the gap.

So the script is generated from the target instead. Every routine body in it
came from `pg_get_functiondef()` against a build of `main` from empty; nothing
was retyped. Its order is dependency order rather than filename order.

### What it changes

| | |
|---|---|
| Routines defined or replaced | 32 |
| Routines dropped | 2 |
| Columns added | 2 |
| Triggers emitted by the generators | 34 |
| Write-register rows | 206 asserted |
| `SECURITY DEFINER` register rows | 55 asserted |
| English strings | 22 added |

The largest correction has nothing to do with the eight migrations. Twenty-one
tables are registered in `erp_meta.table_policy` and never had their triggers
emitted, because nothing re-ran the generators after they were created: 18
audit, 8 tenant-freeze, 6 attribution and 2 append-only guards. Until this runs,
changes to those tables do not reach the audit stream, a row can be moved to
another tenant by `UPDATE`, and `approval_routing_stamp` and
`item_code_assignment` can be edited or deleted despite being append-only.

### How it is verified

CI cannot verify this file. CI builds from empty and applies the migration
sequence, on which the script is a no-op by design — so CI proves it does no
harm and never that it does the job.

`20260831_equivalence_check.sh` is the part that proves it does the job. It
builds the repository twice, once without the eight migrations and once whole,
applies the script to the first, and compares the two on ten dimensions:
routines (identity, body digest, `SET` clause, kind, definer, volatility),
columns, triggers, policies, both registers, base-type permissions, English
resources, the Part 5 register, and the execute grants on the public API.

It also applies the script a second time, and applies it to a database that
already carries `main`, because a repair that is not idempotent and not a no-op
on the finished article is a repair nobody can run twice.

```
./supabase/ops/20260831_equivalence_check.sh
```

Last run: identical on all ten dimensions — 779 routines, 3,297 columns, 593
triggers, 240 policies, 206 write-register rows, 55 definer rows, 13 base types,
688 English strings, 90 Part 5 capabilities, 285 grants.

### Applying it

Against the project directly, in one transaction, having read it first. It ends
with all 22 structural assertions, so a database it would leave in a state the
product considers wrong rolls the whole thing back instead.

It does not install any module. Installing sales, procurement and master data on
production is a separate decision and a separate change, and it should follow
this rather than precede it: installing onto a schema that does not match the
repository is how the divergence widened in the first place.

### Applied — 31 August 2026

Applied to `xpzffnnhnhcqyjqcueja` in thirteen migrations named `reconcile_*`,
because the only channel available was the Supabase MCP tool rather than a
`psql` connection: the project has no stored database password anywhere in the
repository or environment, and the egress proxy refuses both `api.supabase.com`
and the project host. Each part was verified against a local build of `main`
before the next was applied.

Twelve of the thirteen dimensions below now match that build **exactly**:

| | on `main` | on production |
|---|---|---|
| `erp_ref` / `erp_meta` / `erp_ai` / `erp_test` / `public` routines | — | identical |
| triggers in the `erp*` schemas | 593 | 593, identical |
| policies | 240 | 240, identical |
| write register | 206 | 206, identical |
| `SECURITY DEFINER` register | 55 | 55, identical |
| base-type permissions | 13 | 13, identical |
| English resources | 688 | 688, identical |
| Part 5 register | 90 | 90, identical |
| `erp` routines | 440 | 440, **8 differ** — see below |

All 22 assertions pass on production. Two of them failed on the first attempt
and both failures were real:

- `assert_isolation()` — six `erp` functions were `SECURITY DEFINER` with no
  register row. Fixed by the six rows the script carries.
- `assert_transaction_control_routines()` — `erp_test.assert_context_not_leaked`
  still carried the `SET search_path` a linter had added, which PostgreSQL
  refuses to let a procedure commit under. This is the guard written for
  exactly that defect catching it in production, on its first run there.

The generator step did what it was written to do: 559 → 593 triggers, and the
audit and attribution coverage reports went from 20 and 14 findings to none.

### Two things this exercise found that the script does not fix

**Production's function bodies have had their comments stripped.** Every
`--` comment is gone from every routine on that database, so `md5(prosrc)`
differs from `main` for essentially all 779 of them while the code is
identical. This is why the verification above compares bodies with comments
removed and whitespace collapsed; a raw comparison reports hundreds of
differences that are not differences. It also means production can never be
made byte-identical to `main` without rewriting every function, which would
be a large change of no behavioural value. Nothing reads a comment: the gate
detection in `erp.public_api_report()` matches on call text, not commentary.

**Eight `erp` routines differ beyond comments, and all eight are inert.**
They were checked one at a time rather than assumed:

| routine | difference |
|---|---|
| `perform_transition` | `main` declares `v_effects jsonb`, never used |
| `open_approval_seq` | `main` initialises `v_made := 0`, always assigned before use |
| `audit_coverage_report` | one string literal on production, two adjacent ones on `main` |
| `decide_approval_task` | production parenthesises the `CASE` before the cast |
| `evaluate_legislation_rules` | `main` selects `b.pack_version`, never referenced |
| `run_legislation_conformance` | the same unused selected column |
| `submit_command` | `main` declares `v_req` in an inner block, production in the outer one |
| `request_approval` | the two supersede/cancel `UPDATE`s run in the opposite order, over the same set |

No gate, guard, permission check or tenant scope differs in any of them. They
were left alone during the repair itself: rewriting the state machine, the
approval router and the integration gateway by hand-typing them through a tool
channel would have been risk without benefit.

`20260901_eight_inert_routines.sql` is the reviewed change that closes them,
for a database reachable by `psql`. It fixes no defect — it exists so that a
body-level comparison between production and `main` comes back clean, which is
what makes the *next* drift visible. Running it is optional and the file says
so.

Note also that the earlier claim that production matched "repository minus the
eight migrations" was established on counts and presence, not on body content.
It held for the shape and not for the text, which is how these eight went
unnoticed until the digests were compared.
