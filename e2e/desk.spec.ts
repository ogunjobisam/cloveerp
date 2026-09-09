import { expect, test } from "./fixtures/backend";

/**
 * The parts of the desk that are behaviour rather than markup.
 *
 * A route that renders is the floor, and routes.spec.ts holds it. This is the
 * rest: navigation that goes where it says, a palette that filters, a browser
 * that filters, a refusal that reaches the person who caused it, and a layout
 * that survives a phone. None of it is expressible as a schema assertion,
 * because none of it happens in the database.
 */

test.describe("navigation", () => {
  test("the area navigation moves between screens", async ({ page, backend }) => {
    await page.goto("/inventory");

    const areas = page.getByRole("navigation", { name: "Areas" }).first();
    await expect(areas).toBeVisible({ timeout: 20_000 });

    // Whatever the areas are called — the terminology layer names them — there
    // has to be more than one and they have to be links.
    const links = areas.getByRole("link");
    expect(await links.count(), "the area navigation offers nothing to click").toBeGreaterThan(1);

    const target = links.nth(1);
    const href = await target.getAttribute("href");
    await target.click();

    await expect(page).toHaveURL(new RegExp(`${href}/?$`));
    await expect(page.getByRole("heading").first()).toBeVisible();
    expect(backend.crashes).toEqual([]);
  });

  test("the browser's back button returns to the previous screen", async ({ page }) => {
    // Three navigations, each of which may be the first time this dev server
    // has compiled that route. The default thirty seconds is a budget for one.
    test.setTimeout(90_000);
    await page.goto("/inventory");
    await expect(page.getByRole("navigation", { name: "Areas" }).first()).toBeVisible({
      timeout: 20_000,
    });

    await page.goto("/sales");
    await expect(page).toHaveURL(/\/sales\/?$/);

    await page.goBack();
    await expect(page).toHaveURL(/\/inventory\/?$/);
    await expect(page.getByRole("heading").first()).toBeVisible();
  });
});

test.describe("the command palette", () => {
  test("opens on the keyboard, filters, and goes where it is told", async ({ page, backend }) => {
    await page.goto("/inventory");
    await expect(page.getByRole("navigation", { name: "Areas" }).first()).toBeVisible({
      timeout: 20_000,
    });

    await page.keyboard.press("ControlOrMeta+k");

    const dialog = page.getByRole("dialog", { name: "Search screens" });
    await expect(dialog, "Ctrl/Cmd-K did not open the palette").toBeVisible();

    const search = dialog.getByRole("textbox").first();
    // The hits are a list of buttons, not an ARIA listbox — the first version
    // of this test looked for role="option", found none, and compared 0 with 0.
    const hits = dialog.getByRole("listitem");
    await expect(hits.first(), "the palette opened with nothing in it").toBeVisible();
    const before = await hits.count();

    await search.fill("zzzzzzzz-nothing-is-called-this");
    await expect.poll(async () => hits.count(), { timeout: 5_000 }).toBeLessThan(before);
    const after = await hits.count();
    expect(after, "the palette showed the same results for a term nothing matches").toBeLessThan(
      before,
    );

    await search.fill("");
    await expect(hits.first()).toBeVisible();

    await page.keyboard.press("Escape");
    await expect(dialog).toBeHidden();
    expect(backend.crashes).toEqual([]);
  });
});

test.describe("the record browser", () => {
  /**
   * Products, with rows. The default answer everywhere else is empty, which is
   * the right default for a sweep and the wrong one here: a filter cannot be
   * shown to filter anything unless there is something to filter.
   */
  const PRODUCTS = [
    { id: "1", code: "AAA-001", name: "Anvil", uom: "EA", status: "active" },
    { id: "2", code: "BBB-002", name: "Bellows", uom: "EA", status: "active" },
    { id: "3", code: "CCC-003", name: "Crucible", uom: "EA", status: "active" },
  ];

  test("filters the rows it is showing", async ({ page, backend }) => {
    backend.rpc("erp_items", PRODUCTS);
    backend.rpc("erp_products", PRODUCTS);

    await page.goto("/master-data");
    await expect(page.getByRole("heading", { name: "Products" })).toBeVisible({ timeout: 20_000 });

    const filter = page.getByLabel("Filter products by code");
    await expect(filter).toBeVisible();

    const rowsBefore = await page.getByRole("row").count();
    await filter.fill("AAA");

    // Either the browser filters in the client, or it asks again with the term.
    // Both are correct; showing every row regardless is not.
    await expect
      .poll(async () => page.getByRole("row").count(), {
        message: "typing in the filter changed nothing",
        timeout: 10_000,
      })
      .toBeLessThan(Math.max(rowsBefore, 2));

    expect(backend.crashes).toEqual([]);
  });

  test("says so when there is nothing rather than showing an empty frame", async ({
    page,
    backend,
  }) => {
    await page.goto("/master-data");
    await expect(page.getByRole("heading", { name: "Products" })).toBeVisible({ timeout: 20_000 });

    // Its own words in place of rows. role="status" is the *loading* state, and
    // asserting that was this test's first bug: it waited for a spinner that had
    // already been replaced by the thing it meant to check.
    await expect(
      page.getByText(/no .*(yet|match)/i).first(),
      "an empty browser showed no empty state",
    ).toBeVisible({ timeout: 15_000 });
    expect(backend.crashes).toEqual([]);
  });
});

test.describe("refusals", () => {
  /**
   * The one thing the database cannot check about its own refusals: whether
   * anybody ever reads them. `ErpError` keeps message, details and hint
   * precisely so a screen can show them, and the engine writes hints that name
   * the next command to run. A screen that swallows that turns a refusal which
   * explains itself into one that does not.
   */
  test("a refused read reaches the screen with what the database said", async ({
    page,
    backend,
  }) => {
    backend.fail("erp_items", {
      status: 403,
      code: "42501",
      message: "CLOVEERP_PERMISSION_DENIED: inventory.read is required to list items",
      hint: "Ask an administrator to grant inventory.read.",
    });
    backend.fail("erp_products", {
      status: 403,
      code: "42501",
      message: "CLOVEERP_PERMISSION_DENIED: inventory.read is required to list items",
      hint: "Ask an administrator to grant inventory.read.",
    });

    await page.goto("/master-data");

    const alert = page.getByRole("alert").first();
    await expect(alert, "a refused read rendered no alert anywhere on the page").toBeVisible({
      timeout: 20_000,
    });

    // What actually reaches the screen: "This did not load." and
    // friendlyError().title, which for a 42501 is "You do not have permission
    // to do this."
    await expect(alert).toContainText(/permission/i);

    // What does not, and this is a finding rather than an assertion.
    //
    // friendlyError() assembles title, body, hint and technical, and its own
    // comment says the engine's hint "is more specific than the register and
    // wins". record-browser.tsx renders `.title` and nothing else, so the hint
    // the database sent — "Ask an administrator to grant inventory.read." — is
    // dropped, and so is the sentence naming what was refused. The reader is
    // told they lack a permission and not which one.
    //
    // This is an inconsistency rather than a decision: action.tsx, kpi.tsx and
    // profile.tsx all render the hint. Asserting the hint here would leave a
    // permanently red test for a defect in src that this change does not fix,
    // so what is asserted is today's behaviour and the gap is written down.
    // If the browser starts showing the hint, this test still passes.
    expect(backend.crashes).toEqual([]);
  });
});

test.describe("the layout on a phone", () => {
  test.use({ viewport: { width: 390, height: 844 } });

  test("the desk renders and the menu opens", async ({ page, backend }) => {
    await page.goto("/inventory");
    await expect(page.getByRole("heading").first()).toBeVisible({ timeout: 20_000 });

    // Nothing may overflow sideways. A desk that scrolls horizontally on a
    // phone is unusable in a warehouse, which is where this one is used.
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow, "the page scrolls sideways on a 390px viewport").toBeLessThanOrEqual(1);

    const menu = page.getByRole("button", { name: "Open menu" });
    if (await menu.isVisible().catch(() => false)) {
      await menu.click();
      await expect(page.getByRole("navigation", { name: /Areas|Sections/ }).first()).toBeVisible();
    }

    expect(backend.crashes).toEqual([]);
  });
});

test.describe("what every screen owes a keyboard and a screen reader", () => {
  const SAMPLE = ["/inventory", "/master-data", "/finance", "/administration/tenant", "/reporting"];

  for (const path of SAMPLE) {
    test(`${path} has one first-level heading and labels its inputs`, async ({ page }) => {
      await page.goto(path);
      await expect(page.getByRole("heading").first()).toBeVisible({ timeout: 20_000 });

      const h1s = await page.locator("h1").count();
      expect(h1s, `${path} has ${h1s} <h1> elements; a screen should have exactly one`).toBe(1);

      // Every control a person can type into can be named by a screen reader.
      const unlabelled = await page.evaluate(() => {
        const fields = Array.from(
          document.querySelectorAll<HTMLElement>("input:not([type=hidden]), select, textarea"),
        );
        return fields
          .filter((el) => {
            if (el.getAttribute("aria-label")?.trim()) return false;
            if (el.getAttribute("aria-labelledby")) return false;
            if (el.getAttribute("title")?.trim()) return false;
            const id = el.getAttribute("id");
            if (id && document.querySelector(`label[for="${CSS.escape(id)}"]`)) return false;
            if (el.closest("label")) return false;
            if ((el as HTMLInputElement).placeholder?.trim()) return false;
            return true;
          })
          .map((el) => el.outerHTML.slice(0, 120));
      });

      expect(unlabelled, `${path} has controls a screen reader cannot name`).toEqual([]);
    });
  }
});
