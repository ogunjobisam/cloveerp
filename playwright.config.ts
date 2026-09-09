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

/**
 * A Chromium that is already on the host.
 *
 * Playwright resolves a browser build pinned to its own version, and a host
 * that provisions Chromium separately — a container image that ships one, a
 * distribution package — will not have that exact build. Downloading a second
 * copy to satisfy the pin is the usual answer and is not available offline, so
 * the path is an input instead. Unset everywhere it is not needed, which is
 * everywhere Playwright installed its own.
 */
const chromiumPath = process.env["CLOVEERP_E2E_CHROMIUM"];

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
    ...(chromiumPath ? { launchOptions: { executablePath: chromiumPath } } : {}),
  },

  projects: [
    // One sign-in, not six. The setup project authenticates both accounts the
    // suite needs and writes their storage states; every test below reuses one
    // of them and none of them types a password.
    { name: "setup", testMatch: /auth\.setup\.ts/ },

    // The suite that talks to a real stack. Six tests, one sign-in, and the
    // only place in this directory where the answers come from a database.
    {
      name: "integration",
      use: { ...devices["Desktop Chrome"] },
      dependencies: ["setup"],
      testMatch: /smoke\.spec\.ts/,
    },

    // The suite that answers Supabase from inside the browser. No stack, no
    // sign-in, no dependency on the project above — which is what lets it run
    // where there is no Docker, this container included, and in a build that
    // has never once managed to start a stack.
    {
      name: "ui",
      use: { ...devices["Desktop Chrome"] },
      testMatch: /(routes|desk)\.spec\.ts/,
      // Ninety seconds, because the first visit to a route compiles it.
      //
      // The suite is pointed at the dev server rather than a preview — the
      // reason is under webServer below — and Vite compiles a route the first
      // time somebody asks for it. Fifty-two routes means fifty-two cold
      // compiles, and under two workers that regularly costs more than the
      // default thirty seconds all by itself. Three runs each failed four or
      // five routes at exactly 30.0s, and never quite the same ones: the
      // giveaway that it was the clock rather than the screens.
      timeout: 90_000,
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
