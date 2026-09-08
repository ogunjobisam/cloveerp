import { expect, test } from "@playwright/test";

import { DEMO, NO_TENANT } from "./accounts";

/**
 * What a browser can see that a schema assertion cannot.
 *
 * Six tests, one per thing that is only true in a browser: the bundle
 * evaluates, the auth boundary renders the right one of its states, a module
 * page draws, and an unknown path lands somewhere deliberate. Everything about
 * who may do what is left to the database and the suites that already prove
 * it — `erp_test.assert_grant_suite`, `erp_test.assert_door_isolation_suite`,
 * `erp.assert_document_create_permissions`. A browser test that asserted a
 * role could not press a button would be a slower, flakier copy of a check
 * that already runs on every build, and it would still not be the enforcement:
 * the database refuses regardless of what the interface renders.
 */

const SIGNED_OUT = { cookies: [], origins: [] };

test.describe("signed out", () => {
  test.use({ storageState: SIGNED_OUT });

  test("the application boots and renders without a client error", async ({ page }) => {
    // Uncaught exceptions only. A console error can be a blocked favicon or a
    // dev-server notice, and a test that failed on those would be quarantined
    // within a fortnight; an unhandled exception is unambiguously the
    // application breaking, which is the thing worth a browser to find.
    const crashes: string[] = [];
    page.on("pageerror", (e) => crashes.push(e.message));

    await page.goto("/");
    await expect(page.locator("body")).not.toBeEmpty();
    expect(crashes, `uncaught client error(s):\n${crashes.join("\n")}`).toEqual([]);
  });

  test("a protected route shows the sign-in screen", async ({ page }) => {
    await page.goto("/inventory");
    await expect(page.getByRole("heading", { name: "Sign in to Clove ERP" })).toBeVisible();
  });

  test("an unknown route renders the not-found state", async ({ page }) => {
    await page.goto("/this-route-does-not-exist");
    await expect(page.getByRole("heading", { name: "404" })).toBeVisible();
  });
});

test.describe("signed in, no organisation", () => {
  test.use({ storageState: NO_TENANT.state });

  test("the onboarding screen renders", async ({ page }) => {
    await page.goto("/inventory");
    // Authenticated, but the JWT subject resolves to no erp.app_user row, so
    // current_tenant_id() is null. Its own screen, deliberately: an empty
    // dashboard here sends a person looking for a bug in the data.
    await expect(page.getByRole("heading", { name: "Create your organisation" })).toBeVisible({
      timeout: 30_000,
    });
  });
});

test.describe("signed in, seeded demo organisation", () => {
  test.use({ storageState: DEMO.state });

  test("the shell renders with navigation", async ({ page }) => {
    await page.goto("/inventory");
    await expect(page.getByRole("navigation", { name: "Areas" }).first()).toBeVisible({
      timeout: 30_000,
    });
  });

  test("a module page renders its heading and a record browser", async ({ page }) => {
    await page.goto("/master-data");

    // The page heading is read through the terminology layer, so a tenant can
    // rename it and this must not assert the words. That it is there, and says
    // something, is the claim.
    const heading = page.getByRole("heading", { level: 1 }).first();
    await expect(heading).toBeVisible({ timeout: 30_000 });
    await expect(heading).not.toBeEmpty();

    // The record browser: its own heading, and the filter that distinguishes it
    // from a panel that merely lists rows.
    await expect(page.getByRole("heading", { name: "Products" })).toBeVisible();
    await expect(page.getByLabel("Filter products by code")).toBeVisible();
  });
});
