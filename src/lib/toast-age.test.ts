import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { goesWithThePage, outcomeToastId, RAISED_WITH_THE_PAGE_MS, raisedAt } from "./toast-age";

/**
 * A toast showing when the page changes goes with the page (5 October
 * re-test): an outcome stayed over the next screen's process strip and its
 * first form, and took the click meant for the strip.
 */

const ROOT = join(import.meta.dir, "..", "..");

describe("a toast's age", () => {
  test("an outcome's id says when it was raised, and no two are the same", () => {
    const a = outcomeToastId(1_000_000);
    const b = outcomeToastId(1_000_000);
    expect(a).not.toBe(b);
    expect(raisedAt(a)).toBe(1_000_000);
    expect(raisedAt(7)).toBeNull();
    expect(raisedAt("something else")).toBeNull();
  });

  test("one raised a moment before the page changed stays; anything older goes", () => {
    const id = outcomeToastId(10_000);
    expect(goesWithThePage(id, 10_000 + RAISED_WITH_THE_PAGE_MS - 1)).toBe(false);
    expect(goesWithThePage(id, 10_000 + RAISED_WITH_THE_PAGE_MS)).toBe(true);
    // A toast whose id says nothing of its age goes.
    expect(goesWithThePage(3, 10_000)).toBe(true);
  });

  test("the outcomes carry it, and the root takes them when the page changes", () => {
    const action = readFileSync(join(ROOT, "src", "components", "erp", "action.tsx"), "utf8");
    expect(action).toContain("const id = outcomeToastId();");
    const root = readFileSync(join(ROOT, "src", "routes", "__root.tsx"), "utf8");
    expect(root).toContain("useToastsGoWithThePage();");
    expect(root).toContain("goesWithThePage(t.id, now)");
  });

  test("a toast lets the pointer through, and is not drawn over a dialog", () => {
    const css = readFileSync(join(ROOT, "src", "styles.css"), "utf8");
    expect(css).toMatch(/\[data-sonner-toast\] \{\s*pointer-events: none;/);
    expect(css).toContain('body:has([role="dialog"], [role="alertdialog"]) [data-sonner-toaster]');
  });
});
