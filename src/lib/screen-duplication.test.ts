import { describe, expect, test } from "bun:test";

import { MODULES } from "./modules";
import { DOCUMENT_READ } from "./stage-records";

/**
 * A module screen does not list the same rows twice.
 *
 * A module with a process strip draws, for the step you are on, the records
 * sitting at it — a searchable, paged list with Show finished, and a panel
 * beside it showing every field of the one you choose. Underneath that, the
 * Dashboard tab draws the module's worklists. Several of them read exactly the
 * door a step above them already lists, so the same rows were on the screen
 * twice, in two shapes, one of them worse: no search, no paging, no history,
 * and only the columns the table had room for.
 *
 * `/procurement` and `/sales` had four such tables each and lost them in the
 * pull request before this one. `/inventory` had two and `/logistics` one, and
 * they are gone here.
 *
 * The rule is checked rather than remembered, because the fault is invisible
 * on inspection: both halves are correct declarations, and only reading the
 * module definition end to end shows that they are the same door.
 */

/** The reads the steps of a module's chain already list. */
function stageDoors(module: (typeof MODULES)[number]): Set<string> {
  const doors = new Set<string>();
  for (const stage of module.flow?.stages ?? []) {
    if (stage.list) doors.add(stage.list.fn);
    // A step naming a document type lists it through the document read, which
    // is the same door under a different argument.
    if (stage.typeCode) doors.add(DOCUMENT_READ);
  }
  return doors;
}

/**
 * The screens this pass did not cover, and what each still repeats.
 *
 * Written down rather than left to be rediscovered: each is a module whose
 * worklist or report reads a door one of its own steps lists. None of them is
 * on the four screens this pass took, and a removal on a screen nobody looked
 * at is a removal nobody judged. A screen added without a line here, and
 * without the duplicate removed, fails the test — which is the point.
 */
const STILL_REPEATING: Readonly<Record<string, string>> = {
  "/finance":
    "The Periods report reads erp_fiscal_periods, which the Close step lists. Another agent is working on that screen.",
  "/planning": "The Planned orders report reads erp_planned_orders, which the Release step lists.",
  "/production":
    "Both the Works orders worklist and the Works order register report read erp_works_orders, which every step of its chain lists.",
  "/quality": "The Quality events worklist reads erp_quality_events, which its own steps list.",
};

describe("a module's panels do not restate its own steps", () => {
  for (const module of MODULES.filter((m) => m.flow)) {
    const doors = stageDoors(module);
    const repeats = [...module.worklists, ...module.reports].filter((p) => doors.has(p.fn));

    test(`${module.path} lists each read once`, () => {
      if (module.path in STILL_REPEATING) {
        // Named above, with its reason. The assertion is that it is still the
        // one thing that was written down, not that nothing repeats.
        expect(repeats.length).toBeGreaterThan(0);
        return;
      }
      expect(repeats.map((p) => `${p.title} (${p.fn})`)).toEqual([]);
    });
  }

  test("every screen written down as still repeating is a module with a chain", () => {
    const paths = MODULES.filter((m) => m.flow).map((m) => m.path);
    for (const path of Object.keys(STILL_REPEATING)) expect(paths).toContain(path);
  });
});

/**
 * The two screens this pass took, named so the removal cannot quietly return.
 *
 * `toEqual([])` above would pass for a module with no worklists at all, which
 * is what `/logistics` now is; these say which doors specifically must not
 * come back as a panel.
 */
describe("the two screens this pass cut", () => {
  const moduleAt = (path: string) => MODULES.find((m) => m.path === path)!;

  test("/inventory keeps Expiry horizon and no longer restates the task lists", () => {
    const stock = moduleAt("/inventory");
    expect(stock.worklists.map((w) => w.fn)).toEqual(["erp_expiry_horizon"]);
    expect(stageDoors(stock)).toContain("erp_count_tasks");
    expect(stageDoors(stock)).toContain("erp_warehouse_tasks");
  });

  test("/logistics has no worklist, because its only door is its steps' own", () => {
    const despatch = moduleAt("/logistics");
    expect(despatch.worklists).toEqual([]);
    expect(stageDoors(despatch)).toContain("erp_shipments");
  });

  test("both say what their action bar holds, rather than that something is in it", () => {
    for (const path of ["/inventory", "/logistics"]) {
      const bar = moduleAt(path).actionBar;
      expect(bar?.title).toBeTruthy();
      expect(bar?.title).not.toBe("What you can do here");
      expect(bar?.note).toBeTruthy();
    }
  });
});
