# Agent guidance

This repository's working conventions live in [`CLAUDE.md`](./CLAUDE.md) —
read that first. It covers where things live, the commands, how to verify work,
the permission model, migrations, hosting and the house conventions.

Two rules worth repeating here for any agent that only reads this file:

- **Never rewrite published history on `main`** — no force-push, rebase, amend
  or squash of pushed commits. The release register and GitHub deployments
  reference commit SHAs, so rewriting main's history breaks the deploy chain.
- **A migration reaches a deployment only through `.github/workflows/deploy.yml`**
  (production, the demonstration, a client's project). Not by hand, not through
  a console, not through a database connector. One writer at a time.

> This project is no longer connected to Lovable (removed 16 October 2026);
> earlier Lovable-specific guidance here has been retired in favour of CLAUDE.md.
