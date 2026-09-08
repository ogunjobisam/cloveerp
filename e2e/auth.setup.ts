import { expect, test as setup } from "@playwright/test";

import { DEMO, NO_TENANT } from "./accounts";

/**
 * Sign in once per account, here, and never again.
 *
 * Both accounts exist already: the build creates them through the local
 * stack's admin API before Playwright starts, because creating a user is not
 * something the application offers and a test that reached for the service
 * role key would be holding a key no browser should ever see.
 *
 * The sign-in itself goes through the real screen rather than a token written
 * into storage. It costs two page loads and it means the suite would notice if
 * the form stopped submitting — which is the one part of authentication that
 * lives in this repository rather than in Supabase.
 */

async function signIn(
  page: import("@playwright/test").Page,
  account: { email: string; password: string },
) {
  // A protected route rather than /signin: the gate renders the sign-in screen
  // itself when there is no session, so this proves the boundary at the same
  // time as it gets a session.
  await page.goto("/inventory");

  await expect(page.getByRole("heading", { name: "Sign in to Clove ERP" })).toBeVisible();
  await page.getByLabel("Email").fill(account.email);
  await page.getByLabel("Password").fill(account.password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();

  // Whichever state this account resolves to, the sign-in screen is gone.
  await expect(page.getByRole("heading", { name: "Sign in to Clove ERP" })).toBeHidden({
    timeout: 30_000,
  });
}

setup("the no-tenant account signs in and stays without an organisation", async ({ page }) => {
  await signIn(page, NO_TENANT);
  await expect(page.getByRole("heading", { name: "Create your organisation" })).toBeVisible({
    timeout: 30_000,
  });
  await page.context().storageState({ path: NO_TENANT.state });
});

setup("the demo account signs in and seeds its organisation", async ({ page }) => {
  setup.setTimeout(300_000);
  await signIn(page, DEMO);

  // First run seeds; a re-run against a stack that already has the tenant goes
  // straight to the shell, so the onboarding screen is optional here rather
  // than asserted. erp_seed_demo() reuses the caller's existing demo tenant.
  const seed = page.getByRole("button", {
    name: "Explore a seeded demo organisation instead",
  });
  if (await seed.isVisible().catch(() => false)) {
    await seed.click();
  }

  await expect(page.getByRole("navigation", { name: "Areas" })).toBeVisible({ timeout: 240_000 });
  await page.context().storageState({ path: DEMO.state });
});
