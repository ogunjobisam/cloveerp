import type { Page } from "@playwright/test";

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

    // Everything the database said, now that the browser shows it.
    //
    // This asserted only that the word "permission" appeared, and recorded in
    // a comment that the hint was being dropped: record-browser.tsx rendered
    // friendlyError(error).title alone, so "Ask an administrator to grant
    // inventory.read." never arrived and neither did the sentence naming what
    // was refused. It renders ErrorNote now, the same component action.tsx and
    // kpi.tsx use, so the assertion is the whole refusal rather than its first
    // line.
    await expect(alert).toContainText(/permission/i);
    await expect(alert, "the sentence naming what was refused was dropped").toContainText(
      /required to list items/i,
    );
    await expect(alert, "the engine's hint was dropped").toContainText(
      /ask an administrator to grant inventory\.read/i,
    );

    expect(backend.crashes).toEqual([]);
  });
});

test.describe("one panel's data cannot cost the application", () => {
  /**
   * The regression test for the blast radius.
   *
   * Five components read an array field off a query result without checking it
   * was there — ServiceBanner, the notification preferences, the commercial
   * agreement, the analytics contract and the accessibility statement. Because
   * every one of them renders inside the shell, the throw reached the root
   * error boundary, so an unexpected payload from one banner did not cost the
   * banner: it cost every screen in the product, which became "This page
   * didn't load".
   *
   * `callErp<T>()` casts rather than checks, so the type argument is a promise
   * about the response and not a guarantee of it. This sends the emptiest
   * thing JSON can carry to each of the five and asserts the desk survives it.
   * A correct database never sends this; the point is what happens when
   * something does.
   */
  const NAKED = [
    "erp_service_notices",
    "erp_my_notification_settings",
    "erp_my_agreement",
    "erp_analytics_contract",
    "erp_accessibility_statement",
  ];

  for (const [path, fn] of [
    ["/inventory", "erp_service_notices"],
    ["/notifications", "erp_my_notification_settings"],
    ["/administration/commercial", "erp_my_agreement"],
    ["/reporting/distribution", "erp_analytics_contract"],
    ["/administration/accessibility", "erp_accessibility_statement"],
  ] as const) {
    test(`${path} survives ${fn} answering with nothing`, async ({ page, backend }) => {
      for (const name of NAKED) backend.rpc(name, {});

      await page.goto(path);

      await expect(
        page.getByRole("heading", { name: "This page didn't load" }),
        `${fn} returning {} took down ${path}`,
      ).toBeHidden();
      await expect(page.getByRole("heading").first()).toBeVisible({ timeout: 30_000 });
      expect(backend.crashes, `${path} threw:\n${backend.crashes.join("\n")}`).toEqual([]);
    });
  }
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

test.describe("a document offers only what can be completed", () => {
  // The database says which moves the person may make, whether each guard
  // passes against the document, and which the door would refuse
  // (public.erp_available_transitions, 20260923600000); the page draws the
  // ones that would go through and says once why the rest are not there.
  const DOC_ID = "00000000-0000-4000-8000-00000000d0c5";
  const move = (code: string, name: string, extra: Record<string, unknown> = {}) => ({
    code,
    name,
    to_state: code,
    permitted: true,
    guard_passes: true,
    is_automatic: false,
    refused: null,
    ...extra,
  });
  const MOVES = [
    move("approve", "Approve", { refused: "CLOVEERP_DOCUMENT_APPROVAL_PENDING" }),
    move("receive_rest", "Receive the rest"),
    move("close", "Close", { guard_passes: false }),
    move("cancel_approved", "Cancel", { permitted: false }),
    move("receive_all", "Receive all"),
  ];

  test("a refused, guarded, unpermitted or door-only move is not a button, and a line past its cut-off has no Amend", async ({
    page,
    backend,
  }) => {
    backend.rpc("erp_document", {
      document: {
        document_id: DOC_ID,
        document_number: "PO-000042",
        document_type: "purchase_order",
        document_date: "2026-09-01",
        currency: "GBP",
        party: "A Supplier",
        their_reference: null,
        total_minor: 10000,
        state: "sent",
        state_name: "Issued to supplier",
        is_committed: true,
      },
      lines: [
        {
          line_id: "00000000-0000-4000-8000-0000000011e1",
          line_no: 1,
          description: "Widgets",
          quantity: 10,
          unit_price_minor: 1000,
          net_minor: 10000,
          item: "WID",
          supplier_item_code: null,
        },
      ],
      lineage: [],
      reversal: [],
      amendment: {
        allowed: false,
        cut_off: "stock_has_moved",
        detail:
          "stock has left against this document; amend by returning it, not by editing the document",
      },
      available_transitions: MOVES,
    });
    backend.rpc("erp_available_transitions", MOVES);

    await page.goto(`/documents/${DOC_ID}`);
    await expect(page.getByText("PO-000042").first()).toBeVisible({ timeout: 20_000 });

    // The one move that would go through is drawn, under its explained name.
    await expect(page.getByRole("button", { name: "Close short" })).toBeVisible();
    // The rest are not drawn at all, disabled or otherwise.
    for (const name of ["Approve", "Close without the bill", "Cancel", "Receive all"]) {
      await expect(page.getByRole("button", { name, exact: true })).toHaveCount(0);
    }
    // Why, once each.
    await expect(page.getByText("Waiting on somebody else's approval.")).toBeVisible();
    await expect(
      page.getByText("Some moves wait on a condition this document does not meet yet."),
    ).toBeVisible();

    // A line past its cut-off offers no Amend, and says why.
    await expect(page.getByRole("button", { name: "Amend", exact: true })).toHaveCount(0);
    await expect(page.getByText(/No line can be amended now: stock has left/)).toBeVisible();
    expect(backend.crashes).toEqual([]);
  });
});

test.describe("the counter works down a list", () => {
  // The worklist on /inventory/audit (PR10 M3b): a count is one press per
  // place, down the sheet in its order, and what waits on somebody says why and
  // offers only what its door accepts. The shapes are erp_count_tasks' as
  // 20260927400000 left it and erp_render_count_sheet's (20260927100000).
  const SITE = "00000000-0000-4000-8000-0000000000d1";
  const SHEET = "00000000-0000-4000-8000-00000000c007";
  const id = (n: number) => `00000000-0000-4000-8000-0000000c${String(n).padStart(4, "0")}`;
  const A01 = id(1);
  const A02 = id(2);
  const LOOSE = id(3);

  const task = (over: Record<string, unknown>) => ({
    task_id: id(99),
    item: "P9",
    item_name: null,
    batch: null,
    site: "S1",
    site_id: SITE,
    location: "Z-99",
    programme: "cycle_a",
    expected: 10,
    counted: null,
    variance: null,
    within_tolerance: null,
    status: "open",
    counted_at: null,
    posted_at: null,
    document_id: null,
    document_number: null,
    sheet_line_no: null,
    adjustment_document_id: null,
    adjustment_number: null,
    posted_by_system: false,
    post_held_reason: null,
    counted_by_me: false,
    post_refused_to_me: false,
    ...over,
  });
  const onSheet = { document_id: SHEET, document_number: "CNT-000007" };

  const ROWS = [
    // Listed out of order on purpose: the screen walks the paper's.
    task({ task_id: LOOSE, item: "P3", item_name: "Loose", location: "C-01" }),
    task({
      task_id: A02,
      item: "P2",
      item_name: "Second",
      location: "A-02",
      sheet_line_no: 2,
      ...onSheet,
    }),
    task({
      task_id: A01,
      item: "P1",
      item_name: "First",
      location: "A-01",
      sheet_line_no: 1,
      ...onSheet,
    }),
    task({
      task_id: id(4),
      item: "H1",
      location: "H-01",
      status: "approved",
      counted: 9,
      variance: -1,
      within_tolerance: true,
      post_held_reason:
        "held_by_policy: the site's count posting policy holds counts inside tolerance for somebody to post",
    }),
    task({
      task_id: id(5),
      item: "H2",
      location: "H-02",
      status: "approved",
      counted: 11,
      variance: 1,
      within_tolerance: true,
      post_held_reason:
        "post_refused: 23502 CLOVEERP_COUNT_HAS_NO_PLACE: the count of H2 names no location",
    }),
    task({
      task_id: id(6),
      item: "K1",
      location: "K-01",
      status: "counted",
      counted: 20,
      variance: 10,
    }),
    task({
      task_id: id(7),
      item: "R1",
      location: "R-01",
      status: "rejected",
      counted: 2,
      variance: -8,
    }),
    task({ task_id: id(8), item: "W1", location: "W-01", status: "pending_approval", counted: 3 }),
    task({
      task_id: id(9),
      item: "D1",
      location: "D-01",
      status: "posted",
      posted_by_system: true,
      adjustment_document_id: id(90),
      adjustment_number: "ADJ-000001",
    }),
    task({ task_id: id(10), item: "X1", location: "X-01", status: "cancelled" }),
  ];

  const worklist = (page: Page) =>
    page.locator("section", { has: page.getByRole("heading", { name: "Counts to record" }) });
  const waiting = (page: Page) =>
    page.locator("section", {
      has: page.getByRole("heading", { name: "Counts that wait on somebody" }),
    });

  test("a count is one press per place, and the list is walked in the sheet's order", async ({
    page,
    backend,
  }) => {
    backend.rpc("erp_count_tasks", ROWS);
    await page.goto("/inventory/audit");

    const list = worklist(page);
    await expect(list.getByLabel("Counted A-01 P1")).toBeVisible({ timeout: 20_000 });
    const order = await list
      .locator("tr[data-task]")
      .evaluateAll((trs) => trs.map((tr) => tr.getAttribute("data-task")));
    // The sheet's two lines in order, then the count with no sheet; nothing
    // posted, cancelled or waiting on somebody.
    expect(order).toEqual([A01, A02, LOOSE]);

    backend.rpc("erp_record_count", "posted");
    const sent = page.waitForRequest(/rpc\/erp_record_count$/);
    await list.getByLabel("Counted A-01 P1").fill("12");
    await list.getByLabel("Counted A-01 P1").press("Enter");
    const request = await sent;
    expect(request.postDataJSON()).toEqual({ p_task_id: A01, p_quantity: 12 });

    // What the database says once the figure is recorded: posted as it was.
    // Swapped in only now the record has gone, so no read before it sees it.
    backend.rpc(
      "erp_count_tasks",
      ROWS.map((r) =>
        r.task_id === A01
          ? {
              ...r,
              status: "posted",
              counted: 12,
              variance: 2,
              within_tolerance: true,
              posted_by_system: true,
              adjustment_document_id: id(91),
              adjustment_number: "ADJ-000003",
              counted_by_me: true,
            }
          : r,
      ),
    );

    // No dialog, no picker, and the next place is ready for its figure.
    await expect(page.getByRole("dialog")).toHaveCount(0);
    await expect(list.getByLabel("Counted A-02 P2")).toBeFocused();

    const recorded = list.locator(`tr[data-task="${A01}"]`);
    await expect(recorded).toContainText("Posted as it was recorded");
    await expect(recorded.getByRole("link", { name: "ADJ-000003" })).toBeVisible();
    expect(backend.called.filter((fn) => fn === "erp_record_count")).toHaveLength(1);
    expect(backend.crashes).toEqual([]);
  });

  test("an exception says why it waits and offers only what its door accepts", async ({
    page,
    backend,
  }) => {
    backend.rpc("erp_count_tasks", ROWS);
    await page.goto("/inventory/audit");

    const table = waiting(page);
    const row = (n: number) => table.locator(`tr[data-task="${id(n)}"]`);
    await expect(row(4)).toBeVisible({ timeout: 20_000 });
    await expect(table.locator("tr[data-task]")).toHaveCount(5);

    await expect(row(4)).toContainText(
      "The site's count posting policy holds a count inside its tolerance for somebody to post.",
    );
    await expect(row(4).getByRole("button", { name: "Post H-01 H1" })).toBeVisible();

    await expect(row(5)).toContainText("the post was refused");
    await expect(row(5)).toContainText("23502 CLOVEERP_COUNT_HAS_NO_PLACE");

    for (const n of [6, 7]) {
      await expect(row(n).getByRole("button", { name: /^Count it again / })).toBeVisible();
      await expect(row(n).getByRole("button", { name: /^Cancel / })).toBeVisible();
      await expect(row(n).getByRole("button", { name: /^Post / })).toHaveCount(0);
    }

    await expect(row(8)).toContainText("Waiting for its approver.");
    await expect(row(8).getByRole("button")).toHaveCount(0);

    // Cancel asks why, and does not go without an answer.
    await worklist(page)
      .locator(`tr[data-task="${A01}"]`)
      .getByRole("button", { name: "Cancel A-01 P1" })
      .click();
    const dialog = page.getByRole("dialog");
    await expect(dialog).toBeVisible();
    await dialog.getByRole("button", { name: "Cancel the count" }).click();
    await expect(dialog).toBeVisible();
    expect(backend.called).not.toContain("erp_cancel_count_task");

    backend.rpc("erp_cancel_count_task", "cancelled");
    const sent = page.waitForRequest(/rpc\/erp_cancel_count_task$/);
    await dialog.getByLabel(/Why the count is cancelled/).fill("The bay was emptied for a refit");
    await dialog.getByRole("button", { name: "Cancel the count" }).click();
    expect((await sent).postDataJSON()).toEqual({
      p_task_id: A01,
      p_reason: "The bay was emptied for a refit",
    });
    expect(backend.crashes).toEqual([]);
  });

  test("a sheet prints what the database rendered", async ({ page, backend }) => {
    await page.addInitScript(() => {
      window.print = () => {
        (window as unknown as { __printed?: boolean }).__printed = true;
      };
    });
    backend.rpc("erp_count_tasks", ROWS);
    backend.rpc("erp_render_count_sheet", {
      template: "count_sheet",
      title: "Count sheet",
      kind: "document",
      page: "A4",
      locale: "en",
      document_id: SHEET,
      blocks: [
        {
          kind: "title",
          fields: [{ field: "document_number", label: "Number", value: "CNT-000007" }],
        },
        {
          kind: "issuer",
          fields: [{ field: "entity_name", label: "Company", value: "E2E Entity" }],
        },
        {
          kind: "summary",
          fields: [
            { field: "document_date", label: "Date", value: "2026-09-25" },
            { field: "line_count", label: "Lines", value: 2 },
          ],
        },
        {
          kind: "lines",
          columns: [
            { field: "line_no", label: "Line" },
            { field: "location", label: "Place" },
            { field: "item_code", label: "Product code" },
            { field: "expected_quantity", label: "Expected quantity" },
            { field: "counted_quantity", label: "Counted quantity" },
          ],
          // The renderer strips nulls, so the blank arrives as no key at all.
          rows: [
            { line_no: 1, location: "A-01", item_code: "P1", expected_quantity: 10 },
            { line_no: 2, location: "A-02", item_code: "P2", expected_quantity: 10 },
          ],
        },
        { kind: "signature", label: "Counted by" },
      ],
    });
    await page.goto("/inventory/audit");

    const sheet = page.locator('[data-sheet="CNT-000007"]');
    const sent = page.waitForRequest(/rpc\/erp_render_count_sheet$/);
    await sheet
      .getByRole("button", { name: "Print the count sheet CNT-000007" })
      .click({ timeout: 20_000 });
    expect((await sent).postDataJSON()).toEqual({ p_document_id: SHEET });

    const paper = page.locator("[data-print-root]");
    await expect(paper.getByRole("heading", { name: "CNT-000007" })).toBeVisible();
    for (const label of ["Place", "Product code", "Expected quantity", "Counted quantity"]) {
      await expect(paper.getByRole("columnheader", { name: label })).toBeVisible();
    }
    await expect(paper.getByRole("row")).toHaveCount(3);
    await expect(paper.locator("td[data-blank]")).toHaveCount(2);
    for (const blank of await paper.locator("td[data-blank]").all()) {
      await expect(blank).toHaveText("");
    }
    await expect(paper).toContainText("Counted by");
    expect(
      await page.evaluate(() => (window as unknown as { __printed?: boolean }).__printed),
    ).toBe(true);

    // On paper, the sheet and nothing of the desk: not even the parts of it
    // that know nothing of printing, which only the print rule takes away.
    await expect(page.getByRole("heading", { name: "Balances by location" })).toBeVisible();
    await page.emulateMedia({ media: "print" });
    await expect(page.getByRole("heading", { name: "Balances by location" })).toBeHidden();
    await expect(page.getByRole("heading", { name: "Stock audit", level: 1 })).toBeHidden();
    await expect(paper.getByRole("heading", { name: "CNT-000007" })).toBeVisible();
    expect(backend.crashes).toEqual([]);
  });
});
