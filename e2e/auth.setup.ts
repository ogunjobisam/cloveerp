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

setup("the no-tenant account signs in and is asked for an invitation", async ({ page }) => {
  await signIn(page, NO_TENANT);
  // Organisations come by invitation, and self-service sign-up is closed on a
  // stack nobody has opened it on, so an ordinary account with no organisation
  // is asked for an invitation rather than offered to create one.
  await expect(page.getByRole("heading", { name: "You need an invitation" })).toBeVisible({
    timeout: 30_000,
  });
  await page.context().storageState({ path: NO_TENANT.state });
});

setup("the demo account signs in and seeds its organisation", async ({ page }) => {
  setup.setTimeout(300_000);
  await signIn(page, DEMO);

  const shell = page.getByRole("navigation", { name: "Areas" }).first();
  const seed = page.getByRole("button", {
    name: "Explore a seeded demo organisation instead",
  });
  const invitationOnly = page.getByRole("heading", { name: "You need an invitation" });

  // One of three: the shell (a re-run against a stack that already has the
  // tenant), the demo button (platform staff), or the invitation card.
  await expect(shell.or(seed).or(invitationOnly).first()).toBeVisible({ timeout: 30_000 });

  if (await invitationOnly.isVisible()) {
    // A demo organisation is for platform staff while self-service sign-up is
    // closed. A fresh stack has no platform owner, and the console lets the
    // first account to ask become one — the same way the product's owner did
    // on the day it was first deployed. So this account claims it, and is then
    // offered the demo as staff are. The database decides both; nothing here
    // reaches past the screens.
    await page.goto("/platform");
    const claim = page.getByRole("button", { name: "Claim ownership" });
    const notStaff = page.getByText("This account is not on the platform staff list.");
    await expect(claim.or(notStaff).first()).toBeVisible({ timeout: 30_000 });
    if (!(await claim.isVisible())) {
      throw new Error(
        `${DEMO.email} is not platform staff and this stack already has an owner, so it cannot ` +
          "seed a demo while self-service sign-up is closed. Use a fresh stack, or add the " +
          "account to the platform staff from the console.",
      );
    }
    await claim.click();
    await expect(page.getByRole("heading", { name: "Overview", level: 1 })).toBeVisible({
      timeout: 30_000,
    });

    await page.goto("/inventory");
    await expect(shell.or(seed).first()).toBeVisible({ timeout: 30_000 });
  }

  // erp_seed_demo() reuses the caller's existing demo tenant, so a re-run that
  // somehow lands here again seeds nothing twice.
  if (await seed.isVisible().catch(() => false)) {
    await seed.click();
  }

  await expect(shell).toBeVisible({ timeout: 240_000 });
  await page.context().storageState({ path: DEMO.state });
});
