import { expect, test } from "@playwright/test";

import { DEMO, NO_TENANT } from "./accounts";
import { pathsOnTheDemoPath } from "./demo-path";

/**
 * What a browser can see that a schema assertion cannot.
 *
 * One test per thing that is only true in a browser: the bundle evaluates,
 * the auth boundary renders the right one of its states, a module page
 * draws, an unknown path lands somewhere deliberate, and every screen the two
 * demonstrated flows pass through renders on a seeded organisation's own data. Everything about
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
    // dashboard here sends a person looking for a bug in the data. And since
    // organisations come by invitation, what that screen asks an ordinary
    // account for is an invitation.
    await expect(page.getByRole("heading", { name: "You need an invitation" })).toBeVisible({
      timeout: 30_000,
    });
    await expect(page.getByRole("heading", { name: "Create your organisation" })).toBeHidden();
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

  // Definition of Done DEM-03: "Walk both flows front to back. Expect: no
  // console errors, no unhandled exceptions, no dead ends, no empty grids
  // where data should be." The route sweep in routes.spec.ts answers every
  // call with an empty default, so a screen that breaks on real rows is
  // invisible there. This visits every screen on the demo path, in the order
  // the flows reach them, as the seeded organisation, and fails on an
  // unhandled exception, the error screen, or a database read that answered
  // 4xx or 5xx. The document screen is reached from a list in a real walk and
  // has no fixed address, so it is left to the desk suite.
  test("every screen on the demo path renders on the seeded organisation's data", async ({
    page,
  }) => {
    test.setTimeout(10 * 60_000);
    const crashes: string[] = [];
    const refused: string[] = [];
    page.on("pageerror", (e) => crashes.push(`${new URL(page.url()).pathname}: ${e.message}`));
    page.on("response", (r) => {
      if (r.url().includes("/rest/v1/") && r.status() >= 400) {
        refused.push(`${new URL(page.url()).pathname}: ${r.status()} ${new URL(r.url()).pathname}`);
      }
    });

    const paths = pathsOnTheDemoPath().filter(
      (p) => p !== "/signin" && !p.startsWith("/documents/"),
    );
    expect(paths.length).toBeGreaterThan(5);
    for (const path of paths) {
      await page.goto(path);
      const heading = page.getByRole("heading", { level: 1 }).first();
      await expect(heading, `${path} drew no heading`).toBeVisible({ timeout: 30_000 });
      await expect(heading, `${path} drew no heading`).not.toBeEmpty();
      await expect(
        page.getByRole("heading", { name: "This page didn't load" }),
        `${path} fell to the error screen`,
      ).toBeHidden();
      // The reads a screen starts as it opens, answered before the next one.
      await page.waitForTimeout(2_000);
    }

    expect(crashes, `uncaught client error(s):\n${crashes.join("\n")}`).toEqual([]);
    expect(refused, `database reads that failed:\n${refused.join("\n")}`).toEqual([]);
  });
});
