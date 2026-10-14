import type { Page } from "@playwright/test";

import { expect, test } from "./fixtures/backend";
import { ROUTES } from "./routes";

/**
 * Every screen, and every form behind its Actions button, at a phone's width
 * (theme 4, "phones and scanners").
 *
 * The desk was built at a desk and has a drawer for the rail below the md
 * breakpoint, but nothing ever looked at it on a phone: a form, a filter row
 * or a heading with its actions beside it that is wider than the screen puts
 * the action that was meant to be pressed off the edge. The shell hides what
 * overflows as a backstop (shell.tsx), so on the desk such a mistake is not a
 * page that scrolls but a control cut off, which no scroll check sees.
 *
 * So what is measured is every element: nothing may run past the screen's
 * right edge unless it sits in a box made to scroll sideways (a Table scrolls
 * inside its own box, deliberately; panel.tsx). A box that only scrolls
 * vertically, as a form's dialog does, is not one.
 */

type Fit = { count: number; wider: string[]; scroll: number };

async function measure(page: Page): Promise<Fit> {
  // A panel slides in and a dialog zooms: measured mid-animation, it is still
  // partly off the screen it is about to fit.
  await page.evaluate(() => Promise.all(document.getAnimations().map((a) => a.finished)));
  return page.evaluate(() => {
    const width = document.documentElement.clientWidth;
    const sideways = (p: Element) => {
      const o = getComputedStyle(p).overflowX;
      const cls =
        typeof (p as HTMLElement).className === "string" ? (p as HTMLElement).className : "";
      return (o === "auto" || o === "scroll") && /\boverflow-(x-)?(auto|scroll)\b/.test(cls);
    };
    const wider = [...document.querySelectorAll<HTMLElement>("body *")].filter((el) => {
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0 || r.right <= width + 1) return false;
      if (getComputedStyle(el).visibility === "hidden") return false;
      // An empty decoration (a glow, a shape) clipped by its card is the
      // design; what matters is words or a control past the edge.
      const interactive = "a,button,input,select,textarea,[role=button]";
      if (
        (el.textContent ?? "").trim() === "" &&
        !el.matches(interactive) &&
        !el.querySelector(interactive)
      )
        return false;
      for (let p = el.parentElement; p; p = p.parentElement) {
        if (sideways(p)) return false;
        // Clipped on purpose: a truncated label, whose ellipsis is the design.
        // Any other clipping (the shell's backstop, a card that hides what
        // overflows) is a control cut off at the edge.
        const st = getComputedStyle(p);
        if (
          (st.overflowX === "hidden" || st.overflowX === "clip") &&
          (st.textOverflow === "ellipsis" || st.webkitLineClamp !== "none")
        )
          return false;
      }
      return true;
    });
    return {
      count: wider.length,
      scroll: document.documentElement.scrollWidth - width,
      wider: wider.slice(0, 4).map((el) => {
        const cls = typeof el.className === "string" ? el.className.slice(0, 80) : "";
        const text = (el.textContent ?? "").trim().slice(0, 40);
        return `<${el.tagName.toLowerCase()} class="${cls}"> "${text}" right ${Math.round(el.getBoundingClientRect().right)}`;
      }),
    };
  });
}

/** The page again, with nothing open: a closing dialog can still be animating. */
async function fresh(page: Page, path: string) {
  await page.goto(path);
  await expect(page.getByRole("heading").first()).toBeVisible({ timeout: 20_000 });
  await page.waitForLoadState("networkidle");
}

function fits(where: string, fit: Fit) {
  expect(
    fit.count,
    `${where} has ${fit.count} element(s) past the screen's edge at a phone's width:\n  ${fit.wider.join("\n  ")}`,
  ).toBe(0);
  expect(
    fit.scroll,
    `${where} scrolls sideways by ${fit.scroll}px at a phone's width`,
  ).toBeLessThanOrEqual(1);
}

test.describe("at a phone's width, an organisation with no data yet", () => {
  for (const route of ROUTES) {
    test(`${route.path} fits the screen`, async ({ page, backend }) => {
      await page.goto(route.path);
      const heading = page.getByRole("heading").first();
      await expect(heading, `${route.path} rendered no heading`).toBeVisible({ timeout: 20_000 });
      await page.waitForLoadState("networkidle");

      fits(route.path, await measure(page));
      expect(backend.crashes, `${route.path} threw:\n${backend.crashes.join("\n")}`).toEqual([]);
    });
  }

  for (const route of ROUTES.filter((r) => r.kind === "desk")) {
    test(`${route.path}: every form behind Actions fits the screen`, async ({ page, backend }) => {
      test.setTimeout(300_000);
      await fresh(page, route.path);

      const opener = page.locator('main button[aria-haspopup="dialog"]').first();
      if ((await opener.count()) === 0) return;

      await opener.click();
      const panel = page.getByRole("dialog").last();
      await expect(panel).toBeVisible();
      fits(`${route.path} (the Actions panel)`, await measure(page));
      const verbs = await panel.getByRole("button").allTextContents();

      for (const verb of verbs
        .map((v) => v.trim())
        .filter((v) => v !== "" && !["Close", "Show more", "Show less"].includes(v))) {
        await fresh(page, route.path);
        await opener.click();
        const shown = page.getByRole("dialog").last();
        await expect(shown).toBeVisible();
        const button = shown.getByRole("button", { name: verb, exact: true }).first();
        if ((await button.count()) === 0) continue;
        await button.click();
        // The form, in its own dialog, with its pickers loaded.
        await page.waitForLoadState("networkidle");
        fits(`${route.path} → ${verb}`, await measure(page));
      }
      expect(backend.crashes, `${route.path} threw:\n${backend.crashes.join("\n")}`).toEqual([]);
    });
  }
});
