/**
 * The two accounts the suite needs, and the files their sessions live in.
 *
 * Two rather than one because two of the gate's four states are only reachable
 * by a signed-in person, and they are mutually exclusive: a principal either
 * resolves to a tenant or does not. Seeding the demo organisation on the one
 * account would destroy the state the onboarding test exists to see, and
 * ordering the tests so that it happens afterwards is a dependency between
 * tests that a parallel run is entitled to break.
 *
 * So the no-tenant account is never seeded, by construction. It is not a
 * fixture anyone has to remember to leave alone; it is a second row.
 */

export const NO_TENANT = {
  email: process.env["E2E_NO_TENANT_EMAIL"] ?? "e2e-no-tenant@clove.invalid",
  password: process.env["E2E_NO_TENANT_PASSWORD"] ?? "e2e-no-tenant-password-1",
  state: "e2e/.auth/no-tenant.json",
} as const;

export const DEMO = {
  email: process.env["E2E_DEMO_EMAIL"] ?? "e2e-demo@clove.invalid",
  password: process.env["E2E_DEMO_PASSWORD"] ?? "e2e-demo-password-1",
  state: "e2e/.auth/demo.json",
} as const;
