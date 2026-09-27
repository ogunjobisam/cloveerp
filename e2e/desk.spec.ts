import type { Page } from "@playwright/test";

import { DEMO_SESSION, expect, test } from "./fixtures/backend";

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

test.describe("stock's decisions are on the rows, and its page carries its day", () => {
  // PR11 M6. A transfer over its organisation's threshold waits in Pending
  // approval; one under it is raised approved (20260928200000). The row draws
  // Approve and Reject from erp_available_transitions, and only on a row that
  // waits, so a transfer under the threshold never shows either.
  const doc = (n: number) => `00000000-0000-4000-8000-0000000f${String(n).padStart(4, "0")}`;
  const transfer = (n: number, state: string, quantity: number) => ({
    document_id: doc(n),
    document_number: `TRF-00000${n}`,
    state,
    from_site: "ZZ-A",
    to_site: "ZZ-B",
    document_date: "2026-09-26",
    required_date: null,
    lines: 1,
    quantity,
    in_transit: 0,
    value_moved_minor: 0,
    currency: "GBP",
  });
  const move = (
    code: string,
    name: string,
    to_state: string,
    extra: Record<string, unknown> = {},
  ) => ({
    code,
    name,
    to_state,
    permitted: true,
    guard_passes: true,
    is_automatic: false,
    refused: null,
    ...extra,
  });
  const DECIDE = [
    move("approve", "Approve", "approved"),
    move("approve_within_threshold", "Approve within threshold", "approved", {
      is_automatic: true,
    }),
    move("reject", "Reject", "draft"),
  ];

  test("Approve appears only on a transfer over the threshold, and goes through the transition door", async ({
    page,
    backend,
  }) => {
    backend.rpc("erp_transfer_orders", [
      transfer(1, "approved", 1),
      transfer(2, "pending_approval", 5),
      transfer(3, "closed", 2),
    ]);
    backend.rpc("erp_available_transitions", DECIDE);
    const asked: unknown[] = [];
    page.on("request", (r) => {
      if (r.url().endsWith("/rpc/erp_available_transitions")) asked.push(r.postDataJSON());
    });
    await page.goto("/inventory/transfers");

    const row = (n: number) => page.getByRole("row", { name: new RegExp(`TRF-00000${n}`) });
    await expect(row(2).getByRole("button", { name: "Approve TRF-000002" })).toBeVisible({
      timeout: 20_000,
    });
    await expect(row(2).getByRole("button", { name: "Reject TRF-000002" })).toBeVisible();
    // Derived, and never a button.
    await expect(page.getByRole("button", { name: /Approve within threshold/ })).toHaveCount(0);
    // Under the threshold, and finished: nothing to decide, and nothing asked.
    for (const n of [1, 3]) {
      await expect(row(n).getByRole("button", { name: /^(Approve|Reject) / })).toHaveCount(0);
    }
    expect(asked).toEqual([{ p_document_id: doc(2) }]);

    backend.rpc("erp_transition_document", { document_id: doc(2), state: "approved" });
    const sent = page.waitForRequest(/rpc\/erp_transition_document$/);
    await row(2).getByRole("button", { name: "Approve TRF-000002" }).click();
    expect((await sent).postDataJSON()).toEqual({
      p_document_id: doc(2),
      p_transition_code: "approve",
    });
    expect(backend.crashes).toEqual([]);
  });

  test("the person who raised it is not offered Approve, and is told why", async ({
    page,
    backend,
  }) => {
    backend.rpc("erp_transfer_orders", [transfer(2, "pending_approval", 5)]);
    backend.rpc("erp_available_transitions", [
      move("approve", "Approve", "approved", { refused: "CLOVEERP_DOCUMENT_SELF_APPROVAL" }),
      move("reject", "Reject", "draft", { permitted: false }),
    ]);
    await page.goto("/inventory/transfers");

    const row = page.getByRole("row", { name: /TRF-000002/ });
    await expect(row).toContainText("You asked for this approval, so somebody else gives it.", {
      timeout: 20_000,
    });
    await expect(row.getByRole("button")).toHaveCount(0);
    expect(backend.crashes).toEqual([]);
  });

  test("an adjustment waiting for approval gets the same decision, with nothing named for it", async ({
    page,
    backend,
  }) => {
    const adjustment = (n: number, state: string) => ({
      document_id: doc(10 + n),
      document_number: `ADJ-00000${n}`,
      state,
      site: "ZZ-A",
      adjusted_on: "2026-09-26",
      reason_code: "DAMAGE",
      reason_note: null,
      lines: 1,
      found: 0,
      missing: 30,
      cost_minor: 15000,
      currency: "GBP",
    });
    backend.rpc("erp_stock_adjustments", [
      adjustment(1, "draft"),
      adjustment(2, "pending_approval"),
    ]);
    backend.rpc("erp_available_transitions", DECIDE);
    await page.goto("/inventory/adjustments");

    const row = (n: number) => page.getByRole("row", { name: new RegExp(`ADJ-00000${n}`) });
    await expect(row(2).getByRole("button", { name: "Approve ADJ-000002" })).toBeVisible({
      timeout: 20_000,
    });
    await expect(row(1).getByRole("button", { name: /^(Approve|Reject) / })).toHaveCount(0);
    expect(backend.crashes).toEqual([]);
  });

  test("Stock's page carries three daily actions, and the exceptions drawer holds the rest", async ({
    page,
    backend,
  }) => {
    await page.goto("/inventory");
    const header = page.locator("header").filter({ has: page.getByRole("heading", { level: 1 }) });
    const daily = ["Raise a transfer order", "Raise a stock adjustment", "Raise count tasks"];
    for (const name of daily) {
      await expect(header.getByRole("button", { name, exact: true })).toBeVisible({
        timeout: 20_000,
      });
    }
    // Only a way to the rest, called for what it is.
    await expect(header.getByRole("button", { name: "Actions" })).toHaveCount(0);

    await header.getByRole("button", { name: "More" }).click();
    const drawer = page.getByRole("dialog", { name: "More" });
    await expect(drawer).toBeVisible();
    await expect(drawer.getByRole("heading", { name: "Less often" })).toBeVisible();
    for (const name of [
      "Use supplier-owned stock",
      "Create a batch",
      "Split a batch",
      "Release a batch",
      "Raise replenishment tasks",
      "Set a standard cost",
    ]) {
      await expect(drawer.getByRole("button", { name, exact: true })).toBeVisible();
    }
    // Not twice: the daily ones are not in the drawer, and a step's verb stays
    // on its step.
    for (const name of [...daily, "Write off stock", "Record a count"]) {
      await expect(drawer.getByRole("button", { name, exact: true })).toHaveCount(0);
    }
    expect(backend.crashes).toEqual([]);
  });
});

test.describe("the close is two presses", () => {
  // PR12 M5. Opening the close runs every task's check and completes what
  // passes; closing asks them again and closes every ledger of the month
  // (20260929200000). The screen draws each press only where
  // erp_close_checklist says its door would take it (20260929400000).
  const GL = "00000000-0000-4000-8000-0000000c0001";
  const COMMIT = "00000000-0000-4000-8000-0000000c0002";
  const TASK = (n: number) => `00000000-0000-4000-8000-0000000c01${String(n).padStart(2, "0")}`;
  const period = (id: string, ledger: string, status = "open") => ({
    fiscal_period_id: id,
    code: "2026-09",
    status,
    starts_on: "2026-09-01",
    ends_on: "2026-09-30",
    ledger,
  });
  const sibling = (id: string, ledger: string, status = "open") => ({
    fiscal_period_id: id,
    code: "2026-09",
    status,
    ledger,
  });
  const task = (n: number, code: string, name: string, extra: Record<string, unknown> = {}) => ({
    task_id: TASK(n),
    code,
    name,
    seq: n * 10,
    status: "complete",
    blocking_check: `erp.assert_${code}()`,
    is_waivable: true,
    blocked_by: null,
    check_passes: true,
    check_failure: null,
    completed_by: "E2E Demo",
    completed_at: "2026-10-01T09:00:00Z",
    waiver_reason: null,
    check_output: `${name}: holds`,
    owner_role_code: null,
    can_complete: false,
    can_waive: false,
    ...extra,
  });
  const checklist = (extra: Record<string, unknown>) => ({
    period: period(GL, "GL", "closing"),
    tasks: [],
    state: "not_opened",
    blocking: null,
    can_open: false,
    can_close: false,
    open_tasks: 0,
    failing_checks: 0,
    failing_since_completed: 0,
    siblings: [sibling(COMMIT, "COMMIT", "closing")],
    checklist_period: { fiscal_period_id: GL, code: "2026-09", ledger: "GL" },
    ...extra,
  });
  const DONE = [
    task(1, "stock_reconciles", "Stock ledger reconciles", { is_waivable: false }),
    task(2, "grni_reviewed", "Goods received not invoiced reviewed"),
    task(3, "trial_balance", "Trial balance reviewed and signed", { is_waivable: false }),
  ];
  const presses = (page: Page) => page.locator("[data-close-presses]");

  test("Open, then Close: two presses, each drawn only where its door takes it", async ({
    page,
    backend,
  }) => {
    backend.rpc(
      "erp_close_checklist",
      checklist({
        period: period(GL, "GL"),
        siblings: [sibling(COMMIT, "COMMIT")],
        checklist_period: null,
        can_open: true,
      }),
    );
    await page.goto("/finance/close");

    await expect(presses(page).getByRole("button", { name: "Open the close" })).toBeVisible({
      timeout: 20_000,
    });
    await expect(presses(page).getByRole("button", { name: "Close the period" })).toHaveCount(0);
    await expect(page.locator("[data-closes-with]")).toContainText("COMMIT 2026-09");

    // What the database says once the close is open: every check passed.
    backend.rpc("erp_open_period_close", 3);
    backend.rpc(
      "erp_close_checklist",
      checklist({ tasks: DONE, state: "ready", can_open: true, can_close: true }),
    );
    const opened = page.waitForRequest(/rpc\/erp_open_period_close$/);
    await presses(page).getByRole("button", { name: "Open the close" }).click();
    expect((await opened).postDataJSON()).toEqual({ p_fiscal_period_id: GL });

    // Nothing to tick: the opening completed all three, and Close is drawn.
    const close = presses(page).getByRole("button", { name: "Close the period" });
    await expect(close).toBeVisible();
    await expect(
      presses(page).getByRole("button", { name: /^(Open the close|Run the checks again)$/ }),
    ).toHaveCount(0);
    await expect(page.locator("tr[data-task]")).toHaveCount(3);
    await expect(page.locator('tr[data-task="grni_reviewed"]')).toContainText(
      "Goods received not invoiced reviewed: holds",
    );
    await expect(page.locator("tr[data-task]").getByRole("button")).toHaveCount(0);

    backend.rpc("erp_close_period", null);
    backend.rpc(
      "erp_close_checklist",
      checklist({
        period: period(GL, "GL", "closed"),
        tasks: DONE,
        state: "closed",
        siblings: [sibling(COMMIT, "COMMIT", "closed")],
      }),
    );
    const closed = page.waitForRequest(/rpc\/erp_close_period$/);
    await close.click();
    expect((await closed).postDataJSON()).toEqual({ p_fiscal_period_id: GL });

    await expect(page.getByText("This period is closed.")).toBeVisible();
    await expect(presses(page)).toHaveCount(0);
    expect(
      backend.called.filter((fn) =>
        ["erp_open_period_close", "erp_close_period", "erp_complete_close_task"].includes(fn),
      ),
    ).toEqual(["erp_open_period_close", "erp_close_period"]);
    expect(backend.crashes).toEqual([]);
  });

  test("a failing task says what its check said and offers a waiver; a tie that fails offers none", async ({
    page,
    backend,
  }) => {
    backend.rpc(
      "erp_close_checklist",
      checklist({
        tasks: [
          DONE[0],
          task(2, "grni_reviewed", "Goods received not invoiced reviewed", {
            status: "open",
            completed_by: null,
            completed_at: null,
            check_output: null,
            check_passes: false,
            check_failure:
              "CLOVEERP_GRNI_DOES_NOT_RECONCILE: account 2100 holds £957.00 more than the open receipts",
            can_waive: true,
          }),
          task(3, "trial_balance", "Trial balance reviewed and signed", {
            status: "open",
            is_waivable: false,
            completed_by: null,
            completed_at: null,
            check_output: null,
            check_passes: false,
            check_failure: "CLOVEERP_TRIAL_BALANCE_UNBALANCED: debits exceed credits by 1",
          }),
        ],
        state: "in_progress",
        blocking: "Goods received not invoiced reviewed is not done yet.",
        can_open: true,
        open_tasks: 2,
        failing_checks: 2,
      }),
    );
    await page.goto("/finance/close");

    const grni = page.locator('tr[data-task="grni_reviewed"]');
    await expect(grni).toContainText("£957.00 more than the open receipts", { timeout: 20_000 });
    await expect(grni).toContainText("Check fails");
    await expect(
      grni.getByRole("button", { name: "Complete Goods received not invoiced reviewed" }),
    ).toHaveCount(0);

    const tie = page.locator('tr[data-task="trial_balance"]');
    await expect(tie).toContainText("debits exceed credits by 1");
    await expect(tie).toContainText("Cannot be waived");
    await expect(tie.getByRole("button")).toHaveCount(0);

    // The checks can be asked again; the month cannot be closed.
    await expect(presses(page).getByRole("button", { name: "Run the checks again" })).toBeVisible();
    await expect(presses(page).getByRole("button", { name: "Close the period" })).toHaveCount(0);

    // A waiver asks why, and does not go without an answer.
    await grni.getByRole("button", { name: "Waive Goods received not invoiced reviewed" }).click();
    const dialog = page.getByRole("dialog");
    await expect(dialog).toBeVisible();
    await dialog.getByRole("button", { name: "Waive" }).click();
    await expect(dialog).toBeVisible();
    expect(backend.called).not.toContain("erp_complete_close_task");

    backend.rpc("erp_complete_close_task", "FAILED: the difference is £957.00");
    const sent = page.waitForRequest(/rpc\/erp_complete_close_task$/);
    await dialog
      .getByLabel(/Why it is passed/)
      .fill("Reviewed with the buyer: a price query on PO-000123");
    await dialog.getByRole("button", { name: "Waive" }).click();
    expect((await sent).postDataJSON()).toEqual({
      p_task_id: TASK(2),
      p_waiver_reason: "Reviewed with the buyer: a price query on PO-000123",
    });
    expect(backend.crashes).toEqual([]);
  });

  test("COMMIT's month reads as GL's checklist, and says which ledger keeps it", async ({
    page,
    backend,
  }) => {
    backend.rpc(
      "erp_close_checklist",
      checklist({
        period: period(COMMIT, "COMMIT", "closing"),
        siblings: [sibling(GL, "GL", "closing")],
        tasks: DONE,
        state: "ready",
        can_close: true,
      }),
    );
    await page.goto("/finance/close");

    await expect(page.locator("[data-checklist-on]")).toContainText("GL 2026-09", {
      timeout: 20_000,
    });
    await expect(page.locator("[data-closes-with]")).toContainText("GL 2026-09");
    await expect(page.locator("tr[data-task]")).toHaveCount(3);
    await expect(page.getByText("The close has not been opened for this period yet.")).toHaveCount(
      0,
    );

    backend.rpc("erp_close_period", null);
    const sent = page.waitForRequest(/rpc\/erp_close_period$/);
    await presses(page).getByRole("button", { name: "Close the period" }).click();
    expect((await sent).postDataJSON()).toEqual({ p_fiscal_period_id: COMMIT });
    expect(backend.crashes).toEqual([]);
  });

  test.describe("somebody who may read the books but not close them", () => {
    test.use({
      session: {
        ...DEMO_SESSION,
        permissions: DEMO_SESSION.permissions.filter((p) => p !== "finance.close_period"),
      },
    });

    test("is offered no press, whatever the checklist says", async ({ page, backend }) => {
      backend.rpc(
        "erp_close_checklist",
        checklist({
          tasks: [
            task(2, "grni_reviewed", "Goods received not invoiced reviewed", {
              status: "open",
              check_passes: false,
              check_failure: "CLOVEERP_GRNI_DOES_NOT_RECONCILE: a difference",
              can_waive: true,
              can_complete: true,
            }),
          ],
          state: "in_progress",
          can_open: true,
          can_close: true,
        }),
      );
      await page.goto("/finance/close");

      await expect(page.locator('tr[data-task="grni_reviewed"]')).toContainText("a difference", {
        timeout: 20_000,
      });
      await expect(presses(page)).toHaveCount(0);
      await expect(page.locator("tr[data-task]").getByRole("button")).toHaveCount(0);
      expect(backend.crashes).toEqual([]);
    });
  });
});

test.describe("the cash documents are on the desk", () => {
  // PR13 M4. Apply cash opens a receipt (20260930000000) and a payment run a
  // payment per supplier (20260930200000). The Cash in step lists the
  // receipts, each outcome names the document it made and links to it, and a
  // payment's page prints its remittance advice. Nobody opens, adds a line to
  // or posts either by hand, so no screen offers it.
  const RCPT = "00000000-0000-4000-8000-00000000ca51";
  const PMT1 = "00000000-0000-4000-8000-00000000ba71";
  const PMT2 = "00000000-0000-4000-8000-00000000ba72";
  const CUST = "00000000-0000-4000-8000-00000000c057";
  const RUN = "00000000-0000-4000-8000-00000000f0a1";
  const receipt = (extra: Record<string, unknown> = {}) => ({
    document_id: RCPT,
    document_number: "RCPT-000012",
    document_type: "cash_receipt",
    document_date: "2026-09-27",
    required_date: null,
    currency: "GBP",
    party: "Vela Industrial",
    total_minor: 70000,
    state: "posted",
    state_name: "Posted",
    is_committed: false,
    is_cancelled: false,
    ...extra,
  });
  const cashDocument = (doc: Record<string, unknown>, lines: Record<string, unknown>[]) => ({
    document: { their_reference: null, ...doc },
    lines,
    lineage: [],
    reversal: [],
    amendment: null,
    available_transitions: [],
  });
  const line = (n: number, description: string, net: number) => ({
    line_id: `00000000-0000-4000-8000-0000000011${String(n).padStart(2, "0")}`,
    line_no: n * 10,
    description,
    quantity: 1,
    unit_price_minor: net,
    net_minor: net,
    item: null,
    supplier_item_code: null,
  });
  const step = (page: Page, label: string) =>
    page.getByRole("button", { name: new RegExp(`^${label}, step \\d+ of 7`) });

  test("Cash in lists its receipts, and Apply cash names the receipt it made and opens it", async ({
    page,
    backend,
  }) => {
    backend.rpc("erp_documents", [receipt()]);
    // The type is configured, so a New would have something to raise.
    backend.rpc("erp_document_types", [
      {
        document_type_id: "00000000-0000-4000-8000-0000000071e1",
        code: "cash_receipt",
        name: "Cash receipt",
        base_type_code: "cash_receipt",
        requires_party: true,
        requires_site: false,
        currency: "GBP",
        create_permission: "finance.post",
      },
    ]);
    backend.rpc("erp_parties", [{ party_id: CUST, code: "VELA", name: "Vela Industrial" }]);
    backend.rpc("erp_apply_cash", [
      {
        subledger_item_id: "00000000-0000-4000-8000-0000000051e1",
        applied_minor: 60000,
        remaining_minor: 10000,
        written_off_minor: 0,
        on_account_minor: 0,
        document_id: RCPT,
      },
      {
        subledger_item_id: null,
        applied_minor: 0,
        remaining_minor: 10000,
        written_off_minor: 0,
        on_account_minor: 10000,
        document_id: RCPT,
      },
    ]);
    backend.rpc(
      "erp_document",
      cashDocument({ ...receipt(), their_reference: "BACS-0927" }, [
        line(1, "INV-000041", 60000),
        line(2, "On account", 10000),
      ]),
    );

    await page.goto("/finance");
    await step(page, "Cash in").click({ timeout: 20_000 });

    // The receipts are the step's list, and choosing one offers what the
    // step offers: Apply cash, and no New, which the database would refuse.
    await page.getByRole("button", { name: /^RCPT-000012/ }).click();
    await expect(page.getByRole("link", { name: "Open the document" })).toBeVisible();
    await expect(page.getByRole("button", { name: /^New cash in/i })).toHaveCount(0);

    await page.getByRole("button", { name: "Apply cash", exact: true }).click();
    const form = page.getByRole("dialog", { name: "Apply cash" });
    await form.getByLabel("Business partner").selectOption(CUST);
    await form.getByLabel("Amount").fill("700.00");
    await form.getByLabel("Currency").selectOption("GBP");
    await form.getByLabel("Reference").fill("BACS-0927");
    const sent = page.waitForRequest(/rpc\/erp_apply_cash$/);
    await form.getByRole("button", { name: "Apply cash" }).click();
    expect((await sent).postDataJSON()).toMatchObject({
      p_party_id: CUST,
      p_amount_minor: 70000,
      p_currency: "GBP",
      p_reference: "BACS-0927",
    });

    // The outcome leads with the receipt, and links to it.
    await expect(
      page.getByText("RCPT-000012: £600.00 applied to 1 open invoice and £100.00 on account."),
    ).toBeVisible();
    await page.getByRole("link", { name: "Open RCPT-000012" }).click();
    await expect(page).toHaveURL(new RegExp(`/documents/${RCPT}$`));
    await expect(page.getByRole("heading", { name: "RCPT-000012", level: 1 })).toBeVisible();

    // Its lines are the cash, and nothing on the page changes them.
    await expect(page.getByRole("cell", { name: "INV-000041" })).toBeVisible();
    await expect(
      page.getByText(/The routine that opened this document wrote its lines/),
    ).toBeVisible();
    for (const name of ["Add line", "Reprice", "Amend", "Post"]) {
      await expect(page.getByRole("button", { name, exact: true })).toHaveCount(0);
    }
    await expect(page.getByRole("button", { name: /remittance/i })).toHaveCount(0);
    expect(backend.crashes).toEqual([]);
  });

  test("paying a run names each supplier's payment, and a payment prints its remittance advice", async ({
    page,
    backend,
  }) => {
    await page.addInitScript(() => {
      window.print = () => {
        (window as unknown as { __printed?: boolean }).__printed = true;
      };
    });
    backend.rpc("erp_payment_proposals", [
      {
        proposal_id: RUN,
        reference: "PAY-000003",
        payment_date: "2026-09-27",
        currency: "GBP",
        total_minor: 90000,
        status: "approved",
      },
    ]);
    backend.rpc("erp_pay_payment_run", {
      proposal_id: RUN,
      reference: "PAY-000003",
      currency: "GBP",
      lines_paid: 3,
      paid_minor: 90000,
      written_off_minor: 0,
      documents_settled: 3,
      held: 0,
      payments: [
        { document_id: PMT1, document_number: "PMT-000001", party_id: "s1", paid_minor: 50000 },
        { document_id: PMT2, document_number: "PMT-000002", party_id: "s2", paid_minor: 40000 },
      ],
    });
    backend.rpc(
      "erp_document",
      cashDocument(
        {
          document_id: PMT1,
          document_number: "PMT-000001",
          document_type: "cash_payment",
          document_date: "2026-09-27",
          currency: "GBP",
          party: "Anvil Supplies",
          total_minor: 50000,
          state: "posted",
          state_name: "Posted",
          is_committed: false,
        },
        [
          line(1, "PINV-000007, your ref AS-1", 20000),
          line(2, "PINV-000008, your ref AS-2", 30000),
        ],
      ),
    );
    backend.rpc("erp_render_remittance_advice", {
      template: "remittance_advice",
      title: "Remittance advice",
      kind: "document",
      page: "A4",
      locale: "en",
      document_id: PMT1,
      blocks: [
        {
          kind: "title",
          fields: [{ field: "document_number", label: "Reference", value: "PMT-000001" }],
        },
        {
          kind: "issuer",
          fields: [{ field: "entity_name", label: "Company", value: "E2E Entity" }],
        },
        {
          kind: "addressee",
          fields: [{ field: "party_name", label: "Supplier", value: "Anvil Supplies" }],
        },
        {
          kind: "lines",
          columns: [
            { field: "line_no", label: "Line" },
            { field: "description", label: "Bill" },
            { field: "net_amount", label: "Paid" },
          ],
          rows: [
            { line_no: 10, description: "PINV-000007, your ref AS-1", net_amount: "200.00" },
            { line_no: 20, description: "PINV-000008, your ref AS-2", net_amount: "300.00" },
          ],
        },
        { kind: "totals", fields: [{ field: "total_net", label: "Total", value: "500.00" }] },
      ],
    });

    await page.goto("/finance");
    await step(page, "Pay").click({ timeout: 20_000 });
    await page.getByRole("button", { name: /^PAY-000003/ }).click();
    await page.getByRole("button", { name: "Pay an approved run", exact: true }).click();
    const sent = page.waitForRequest(/rpc\/erp_pay_payment_run$/);
    await page
      .getByRole("dialog", { name: "Pay an approved run" })
      .getByRole("button", { name: "Pay an approved run" })
      .click();
    expect((await sent).postDataJSON()).toMatchObject({ p_proposal_id: RUN });

    await expect(
      page.getByText("PAY-000003 paid £900.00 to 2 suppliers: PMT-000001 and PMT-000002."),
    ).toBeVisible();
    await expect(page.getByRole("link", { name: "Open PMT-000002" })).toBeVisible();
    await page.getByRole("link", { name: "Open PMT-000001" }).click();
    await expect(page).toHaveURL(new RegExp(`/documents/${PMT1}$`));

    const print = page.getByRole("button", { name: "Print the remittance advice PMT-000001" });
    const rendered = page.waitForRequest(/rpc\/erp_render_remittance_advice$/);
    await print.click({ timeout: 20_000 });
    expect((await rendered).postDataJSON()).toEqual({ p_document_id: PMT1 });

    const paper = page.locator("[data-print-root]");
    await expect(paper.getByRole("heading", { name: "PMT-000001" })).toBeVisible();
    for (const label of ["Bill", "Paid"]) {
      await expect(paper.getByRole("columnheader", { name: label })).toBeVisible();
    }
    await expect(paper.getByRole("row")).toHaveCount(3);
    await expect(paper).toContainText("PINV-000008, your ref AS-2");
    await expect(paper).toContainText("500.00");
    expect(
      await page.evaluate(() => (window as unknown as { __printed?: boolean }).__printed),
    ).toBe(true);
    for (const name of ["Add line", "Reprice", "Amend", "Post"]) {
      await expect(page.getByRole("button", { name, exact: true })).toHaveCount(0);
    }
    expect(backend.crashes).toEqual([]);
  });
});

test.describe("a credit kept on account is allocated from its row", () => {
  // PR13 M5 (20260930400000). Credit on account lists what customers paid
  // beyond what they owed, and Allocate is drawn on a row only where the read
  // says the reader may allocate it and names an invoice to take it.
  const CREDIT = "00000000-0000-4000-8000-00000000cc01";
  const HELD = "00000000-0000-4000-8000-00000000cc02";
  const INV = "00000000-0000-4000-8000-00000000cc11";
  const credit = (extra: Record<string, unknown> = {}) => ({
    credit_item_id: CREDIT,
    party_id: "00000000-0000-4000-8000-00000000c057",
    party_name: "Vela Industrial",
    entity_id: "00000000-0000-4000-8000-0000000000e1",
    company: "MAIN",
    currency: "GBP",
    kept_on: "2026-09-27",
    credit_minor: 10000,
    left_minor: 10000,
    receipt_id: "00000000-0000-4000-8000-00000000ca51",
    receipt_number: "RCPT-000012",
    allocatable: true,
    invoices: [
      { document_id: INV, document_number: "INV-000042", owes_minor: 30000, due_on: "2026-10-27" },
    ],
    ...extra,
  });

  test("Allocate is on the row the database takes it for, and says what it did", async ({
    page,
    backend,
  }) => {
    backend.rpc("erp_on_account_credits", [
      credit(),
      // Another company's, which this reader may not post in, and one with no
      // invoice to take it: neither is offered.
      credit({ credit_item_id: HELD, party_name: "Orla Foods", allocatable: false }),
      credit({
        credit_item_id: "00000000-0000-4000-8000-00000000cc03",
        party_name: "Tern Hardware",
        invoices: [],
      }),
    ]);
    backend.rpc("erp_allocate_on_account", {
      credit_item_id: CREDIT,
      invoice_id: INV,
      invoice_number: "INV-000042",
      allocated_minor: 10000,
      currency: "GBP",
      credit_left_minor: 0,
      invoice_owes_minor: 20000,
      invoice_state: "part_paid",
      journal_id: "00000000-0000-4000-8000-00000000cc21",
      receipt_id: "00000000-0000-4000-8000-00000000ca51",
      receipt_number: "RCPT-000012",
    });

    await page.goto("/finance");
    await expect(page.getByRole("cell", { name: "Orla Foods", exact: true })).toBeVisible({
      timeout: 20_000,
    });
    await expect(page.getByRole("cell", { name: "RCPT-000012" }).first()).toBeVisible();
    const allocate = page.getByRole("button", { name: /^Allocate / });
    await expect(allocate).toHaveCount(1);
    await expect(allocate).toHaveAccessibleName("Allocate £100.00 on account for Vela Industrial");

    await allocate.click();
    const form = page.getByRole("dialog", { name: "Allocate a credit on account" });
    await expect(form.getByLabel("Invoice")).toHaveValue(INV);
    const sent = page.waitForRequest(/rpc\/erp_allocate_on_account$/);
    await form.getByRole("button", { name: "Allocate" }).click();
    const args = (await sent).postDataJSON() as Record<string, unknown>;
    expect(args).toMatchObject({ p_credit_item: CREDIT, p_invoice: INV });
    // Left empty, the amount is the door's to decide.
    expect(args).not.toHaveProperty("p_amount_minor");

    await expect(
      page.getByText(
        "£100.00 of the credit on account allocated to INV-000042, which owes £200.00.",
      ),
    ).toBeVisible();
    await expect(page.getByRole("link", { name: "Open INV-000042" })).toBeVisible();
    expect(backend.crashes).toEqual([]);
  });

  test.describe("somebody who may read the books but not post", () => {
    test.use({
      session: {
        ...DEMO_SESSION,
        permissions: DEMO_SESSION.permissions.filter((p) => p !== "finance.post"),
      },
    });

    test("sees the credit and is offered no Allocate, whatever the row says", async ({
      page,
      backend,
    }) => {
      backend.rpc("erp_on_account_credits", [credit()]);
      await page.goto("/finance");
      await expect(page.getByRole("cell", { name: "Vela Industrial", exact: true })).toBeVisible({
        timeout: 20_000,
      });
      await expect(page.getByRole("button", { name: /^Allocate / })).toHaveCount(0);
      expect(backend.crashes).toEqual([]);
    });
  });
});
