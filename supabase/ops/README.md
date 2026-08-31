# Operations

One-off scripts that repair a specific database. Nothing here is part of the
product's definition, and nothing here runs in CI.

The distinction matters. `supabase/migrations/` is the sequence that builds
ERPWare from nothing, and CI proves on every push that it still does. A script
in this directory is the opposite: it exists because one particular database
drifted from that sequence, and it is written against the state that database
actually reached rather than the state the repository describes.

A file here has done its job once it has been applied. It is kept because the
repair should be reviewable and reproducible, not because it will be needed
again.

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
