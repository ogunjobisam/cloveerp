import { defineConfig, devices } from "@playwright/test";

/**
 * Six tests, and deliberately not a seventh.
 *
 * This is not a role or permission matrix. Permissions are already proved by
 * erp_test.assert_grant_suite, erp_test.assert_door_isolation_suite and
 * erp_test.assert_refusal_register_suite, against the database that actually
 * refuses; a browser walking the same ground would agree with them on a good
 * day and cost maintenance on every other one. What a browser can see and an
 * assertion cannot is whether the application boots, whether the auth boundary
 * renders the screen it is meant to for each of its states, and whether a
 * module page draws. That is the whole remit.
 *
 * The build points this at a Supabase stack it started itself. Two guards
 * below, because the application's default when the environment says nothing
 * is the LIVE project (see src/lib/erp.ts, which inlines it on purpose so that
 * every build starts connected). A test run that signs in and clicks is not
 * something to point at production by accident, and "by accident" is exactly
 * how it would happen: one unset variable.
 */

const PORT = 4173;
const BASE_URL = `http://127.0.0.1:${PORT}`;

/** The live project's ref, from src/lib/erp.ts. Named here to be refused. */
const LIVE_PROJECT_REF = "xpzffnnhnhcqyjqcueja";

const target = process.env["VITE_SUPABASE_URL"];

if (!target) {
  throw new Error(
    "CLOVEERP_E2E_NO_TARGET: VITE_SUPABASE_URL is not set, so the application would fall back to " +
      "the live project. Start a local stack (supabase start) and export its API URL and " +
      "publishable key, or point these tests at a disposable project.",
  );
}

if (target.includes(LIVE_PROJECT_REF)) {
  throw new Error(
    `CLOVEERP_E2E_TARGETS_LIVE: VITE_SUPABASE_URL names the live project (${LIVE_PROJECT_REF}). ` +
      "These tests sign in and seed an organisation; they do not run against production.",
  );
}

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  forbidOnly: Boolean(process.env["CI"]),
  retries: process.env["CI"] ? 1 : 0,
  reporter: process.env["CI"] ? [["github"], ["list"]] : [["list"]],
  timeout: 30_000,
  expect: { timeout: 10_000 },

  use: {
    baseURL: BASE_URL,
    trace: "on-first-retry",
  },

  projects: [
    // One sign-in, not six. The setup project authenticates both accounts the
    // suite needs and writes their storage states; every test below reuses one
    // of them and none of them types a password.
    { name: "setup", testMatch: /auth\.setup\.ts/ },
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
      dependencies: ["setup"],
      testIgnore: /auth\.setup\.ts/,
    },
  ],

  webServer: {
    // The dev server rather than a preview of the build: VITE_* values are
    // inlined at build time, so a preview would carry whatever the build step
    // was given, which is the fallback this file exists to refuse.
    //
    // --host 127.0.0.1 because Vite binds :: by default and a container
    // without IPv6 refuses that with EAFNOSUPPORT before a single test runs.
    // Loopback is also all this needs: nothing outside the runner calls it.
    command: `bunx vite dev --port ${PORT} --strictPort --host 127.0.0.1`,
    url: BASE_URL,
    reuseExistingServer: !process.env["CI"],
    timeout: 180_000,
  },
});
