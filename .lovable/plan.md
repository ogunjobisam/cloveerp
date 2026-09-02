# Verify the Wave C/D database work landed cleanly

Another agent is applying "Wave" SQL chunks straight to the live Clove ERP database. This plan checks that what landed matches the repository source, with no drift, no half-applied chunk, and no broken surface. It is a verification pass — no schema changes unless verification finds a genuine defect, and any fix would be proposed separately.

## What the first look already shows

- Live counts match the figures in the screenshot: 20 policy decisions and 1,049 resource strings.
- The `erp` engine holds 559 routines and the `public` front door exposes 319 `erp_*` wrappers.
- `apply_change_set_item` (the Wave D chunk 1 target) exists on live.
- **Drift signal:** the repository holds 168 migration files, but the database's migration registry records only 160, with the newest recorded version dated 31 Aug. Everything applied since then — including the Wave chunks — is not recorded in the registry. This means the repo and the live database can no longer be compared by version number alone.

## Verification steps

1. **Registry reconciliation.** List the repository migration filenames against the recorded versions and produce the exact set of files present in the repo but absent from the registry, and vice versa.
2. **Object-level presence.** For each unrecorded migration, extract the objects it creates (tables, functions, policies, grants) and confirm each one exists on live with the expected signature. This is the real test, since the registry cannot be trusted.
3. **Body comparison.** For every `erp` and `public` routine that the unrecorded migrations define, compare the live function body against the repository source and report any that differ. This catches a chunk applied from a different branch (`erpware_v13`) than the one in this repo.
4. **Half-applied chunk check.** Confirm no routine is left in a state where it references a table, column, type or helper that does not exist — a fast way to spot a chunk that stopped midway.
5. **Surface health.** Confirm the `public` wrappers still resolve, grants and RLS are intact on every table touched, and no table lost row-level security or gained anonymous access during the applies.
6. **Runtime smoke.** Run the Supabase linter and load the affected screens as an authenticated user to confirm the front end still reads real data without errors.

## What you get

A short report listing, in order of severity: objects missing on live, live bodies that diverge from the repo, any lost security posture, and the reconciliation gap between the repo's migration files and the database registry — with a recommendation on how to bring the registry back in step.

## Note on the other agent

If the other session is still mid-apply, the comparison is a snapshot and results can move under us. Best run once that session reports finished.
