# Re-invites, owner access everywhere, and roles you can combine

Three things you asked for, in one pass.

## 1. Inviting someone again after they were removed

Today a person's record stays on file when they are removed, so inviting the
same address again collides with the record that is already there — the
"That already exists" message in your screenshot.

After this change, inviting an address that is already on file **reuses that
record**: the name is updated to what you typed, the person is put back to
*Invited*, and a fresh single-use token is issued. Their history, past grants
and audit trail stay attached to the same person rather than starting again.

The one refusal that remains: if the address belongs to somebody who is
already active and signed in, inviting them again says so plainly instead of
issuing a token — nothing to re-invite.

Removing a person will also be explicit: they move to *Removed* (grants end
immediately, they cannot sign in) rather than vanishing, so the screen shows
what actually happened in the database.

## 2. The platform owner reaches everything

Owner is currently treated like everyone else once inside an organisation —
so on the demo organisation some actions refuse you. After this change the
platform **Owner** passes every permission check in every organisation, and
Operator/Support keep their present, narrower reach.

Every one of those owner actions is written to the audit trail marked as a
platform action, so "the owner did it" is always visible to the organisation.

## 3. Roles for a job, combined per person

A library of job roles is added, each holding the permissions that job needs:
Inventory, Purchasing, Sales, Finance, Production, Quality, Despatch,
Planning, Reporting, Administrator, Viewer.

A person may hold **several** — Inventory *and* Finance, for example — and
what they can do is everything their roles allow, added together.

The Users and authorisations screen gets a simpler panel: pick a person, tick
the roles they should hold, save. Removing is unticking. The current
one-role-at-a-time form and the grants table stay, showing validity and
reason, for anything time-limited.

## Technical notes

- New forward-only migration(s):
  - `erp.invite_principal` becomes an upsert on `(tenant_id, email)`: reactivate
    to `invited`, refresh `display_name`, issue a new invitation row, and refuse
    when the record already carries an `auth_user_id`. Adds `erp.remove_principal`
    (status `removed`, ends open `user_role` rows).
  - `erp.principal_status` gains `removed` if absent.
  - `erp.authorise()` short-circuits `true` for `erp_meta` platform role
    `owner`, and records the decision as a platform override.
  - Seeded roles + `role_permission` rows per tenant-provisioning path, with a
    backfill for existing tenants.
  - `public.erp_set_user_roles(p_app_user_id, p_role_codes text[], p_reason)`
    replaces the whole set for a person in one call; each public function
    asserts its own governance in the same migration, per house rule.
- Assertions extended rather than manual clicking: `erp_test.assert_grant_suite`
  gains re-invite reuse, owner override, and multi-role composition cases; the
  refusal register keeps its shape.
- UI: `src/routes/administration/permissions.tsx` gains the tick-list role panel
  and a Remove person action; no shadcn primitives touched.
- Checks: `bun run typecheck`, `bun run lint`, `bun run test`,
  `bash supabase/ci/form_fields.sh`, `bun run build`, and the schema assertions.
- Migrations are written as files in `supabase/migrations/` and reach production
  only through `.github/workflows/deploy.yml`, per the repository rule.
