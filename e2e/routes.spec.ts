import { readdirSync, statSync } from "node:fs";
import { join } from "node:path";

import { DEMO_SESSION, expect, test } from "./fixtures/backend";
import { ROUTES } from "./routes";

/**
 * Every screen, rendered against an organisation that has nothing in it yet.
 *
 * The claim each of these makes is small and the same one: this route draws a
 * page, that page has a heading, and nothing threw on the way. It is small on
 * purpose. What it is not is a test of what the screens say — the words come
 * through the terminology layer and a tenant may rename any of them, so
 * asserting them here would fail on a rename that is a feature.
 *
 * The value is in the sweep. Two of these fifty-two routes were covered before;
 * a component that throws on an empty list, a route that stopped resolving, a
 * heading that disappeared behind a loading state that never resolves — none of
 * that was visible anywhere in the build, and none of it is visible to a schema
 * assertion, because none of it is in the schema.
 */

function routeFiles(dir: string, prefix = ""): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) return routeFiles(full, `${prefix}${entry}/`);
    return entry.endsWith(".tsx") && entry !== "__root.tsx" ? [`${prefix}${entry}`] : [];
  });
}

test.describe("the route inventory", () => {
  test("names every route file, and no route file is missing from it", async () => {
    const onDisk = routeFiles("src/routes").sort();
    const named = ROUTES.map((r) => r.file).sort();

    expect(
      named,
      "e2e/routes.ts and src/routes disagree. A new screen needs a line in the inventory; " +
        "a deleted one needs its line removed.",
    ).toEqual(onDisk);
  });
});

test.describe("signed in, an organisation with no data yet", () => {
  for (const route of ROUTES) {
    test(`${route.path} renders`, async ({ page, backend }) => {
      const response = await page.goto(route.path);

      // The dev server answers 200 for every client route; a 404 here would
      // mean the route did not resolve at all.
      expect(response?.status(), `${route.path} did not resolve`).toBeLessThan(400);

      // Something drew. `not.toBeEmpty` rather than a screenshot: what matters
      // is that the shell did not hand back a blank document.
      await expect(page.locator("body")).not.toBeEmpty();

      // Not the error boundary, first and before anything else.
      //
      // The first version of this test asked only for a heading, and passed on
      // every desk route while every one of them was rendering the root error
      // boundary — whose heading is "This page didn't load", which is a
      // heading, and visible, and not empty. A green suite that proves the
      // error page works is worse than no suite, because it is believed.
      await expect(
        page.getByRole("heading", { name: "This page didn't load" }),
        `${route.path} rendered the root error boundary`,
      ).toBeHidden();

      if (route.kind === "desk") {
        // The desk, specifically: the shell's own navigation. This is what
        // distinguishes a screen that loaded from the sign-in screen, the
        // onboarding screen and the boundary, all three of which have a
        // heading and none of which is this route.
        await expect(
          page.getByRole("navigation", { name: "Areas" }).first(),
          `${route.path} did not reach the desk`,
        ).toBeVisible({ timeout: 20_000 });
      }

      // A heading, whatever it says. The words come through the terminology
      // layer and a tenant may rename any of them, so what is asserted is that
      // there is one and it says something.
      const heading = page.getByRole("heading").first();
      await expect(heading, `${route.path} rendered no heading`).toBeVisible({ timeout: 20_000 });
      await expect(heading, `${route.path} rendered an empty heading`).not.toBeEmpty();

      expect(backend.crashes, `${route.path} threw:\n${backend.crashes.join("\n")}`).toEqual([]);
    });
  }
});

test.describe("the gate's other states", () => {
  test.use({ session: null });

  test("a desk route signed out shows the sign-in screen, not a blank page", async ({
    page,
    backend,
  }) => {
    await page.goto("/inventory");
    await expect(page.getByRole("heading", { name: "Sign in to Clove ERP" })).toBeVisible();
    expect(backend.crashes).toEqual([]);
  });

  test("a public route signed out renders without a session", async ({ page, backend }) => {
    await page.goto("/product");
    await expect(page.getByRole("heading").first()).toBeVisible();
    expect(backend.crashes).toEqual([]);
  });

  test("an unknown route lands somewhere deliberate", async ({ page, backend }) => {
    await page.goto("/this-route-does-not-exist");
    await expect(page.getByRole("heading", { name: "404" })).toBeVisible();
    expect(backend.crashes).toEqual([]);
  });
});

test.describe("signed in, but no organisation", () => {
  test.use({
    session: {
      principal_id: null,
      tenant_id: null,
      entities: [],
      sites: [],
      permissions: [],
    },
  });

  test("onboarding is what a principal without a tenant gets", async ({ page, backend }) => {
    await page.goto("/inventory");
    await expect(page.getByRole("heading", { name: "Create your organisation" })).toBeVisible({
      timeout: 20_000,
    });
    expect(backend.crashes).toEqual([]);
  });
});

test.describe("the session itself failing", () => {
  test("a refused session says so rather than showing an empty desk", async ({ page, backend }) => {
    backend.fail("erp_session", {
      status: 500,
      code: "P0001",
      message: "CLOVEERP_SESSION_UNAVAILABLE: the session could not be resolved",
    });

    await page.goto("/inventory");
    await expect(page.getByRole("heading", { name: "Could not load your session" })).toBeVisible({
      timeout: 20_000,
    });
    expect(backend.crashes).toEqual([]);
  });

  test("the demo session reaches the desk", async ({ page, backend }) => {
    backend.rpc("erp_session", DEMO_SESSION);
    await page.goto("/inventory");
    await expect(page.getByRole("navigation", { name: "Areas" }).first()).toBeVisible({
      timeout: 20_000,
    });
    expect(backend.crashes).toEqual([]);
  });
});
