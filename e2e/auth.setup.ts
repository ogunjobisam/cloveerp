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
  setup.setTimeout(900_000);
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
    await expect(page.getByRole("heading", { name: "Today", level: 1 })).toBeVisible({
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

  // A history of trading, as ci-demo is given one (supabase/ci/seed_demo.sql):
  // the seed above makes master data and two drafts and posts nothing, so the
  // walk's screens would rightly be empty, and an empty grid where data should
  // be is what the walk exists to catch (KI-09). The last sixty days, built a
  // slice at a time until the seed says it is done, as the account that may
  // seed demonstrations; with its own session, so the database decides.
  const url = process.env["VITE_SUPABASE_URL"];
  const key = process.env["VITE_SUPABASE_PUBLISHABLE_KEY"];
  const token = await page.evaluate(() => {
    for (let i = 0; i < localStorage.length; i++) {
      const name = localStorage.key(i) ?? "";
      if (/^sb-.*-auth-token$/.test(name)) {
        const session = JSON.parse(localStorage.getItem(name) ?? "{}") as { access_token?: string };
        if (session.access_token) return session.access_token;
      }
    }
    return null;
  });
  if (!url || !key || !token) {
    throw new Error(
      "the demo account's session or the stack's address is missing, so no history could be built",
    );
  }
  let from: string | null = new Date(Date.now() - 60 * 86_400_000).toISOString().slice(0, 10);
  for (let slice = 0; from && slice < 20; slice++) {
    const response = await fetch(`${url}/rest/v1/rpc/erp_seed_demo_history`, {
      method: "POST",
      headers: {
        apikey: key,
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ p_from: from, p_to: null, p_scale: 1 }),
    });
    if (!response.ok) {
      throw new Error(
        `building the demonstration's history answered ${response.status}: ${await response.text()}`,
      );
    }
    const built = (await response.json()) as { done?: boolean; next_from?: string | null };
    from = built.done ? null : (built.next_from ?? null);
  }

  await page.context().storageState({ path: DEMO.state });
});
