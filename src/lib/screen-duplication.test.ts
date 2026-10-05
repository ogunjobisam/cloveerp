import { describe, expect, test } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

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
  "/planning": "The Planned orders report reads erp_planned_orders, which the Release step lists.",
  "/production":
    "The Works order register report reads erp_works_orders, which every step of its chain lists. It is the only report on that tab, and the one table of every order, closed ones included.",
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

  // Its one worklist is what needs a person (20261004600000), a door no step
  // lists; the shipments themselves stay the steps' own.
  test("/logistics lists only what needs a person, never its steps' own shipments", () => {
    const despatch = moduleAt("/logistics");
    expect(despatch.worklists.map((w) => w.fn)).toEqual(["erp_shipment_exceptions"]);
    expect(stageDoors(despatch)).toContain("erp_shipments");
    expect(stageDoors(despatch)).not.toContain("erp_shipment_exceptions");
  });
});

/**
 * Three more, cut after those. `/finance` and `/quality` are off the list
 * above, so the first test holds them to nothing repeated. `/production` is
 * still on it for its register, which would let the worklist come back
 * unnoticed; this says which of the two is the one that stays.
 */
describe("the screens cut after them", () => {
  const moduleAt = (path: string) => MODULES.find((m) => m.path === path)!;

  test("/finance lists its periods on the Close step, counts them on a tile, and has no table of them", () => {
    const finance = moduleAt("/finance");
    expect(stageDoors(finance)).toContain("erp_fiscal_periods");
    expect(finance.reports.map((r) => r.fn)).not.toContain("erp_fiscal_periods");
    expect(finance.kpis.map((k) => k.fn)).toContain("erp_fiscal_periods");
  });

  test("/production keeps the register and no longer restates its steps on the Dashboard", () => {
    const making = moduleAt("/production");
    expect(making.worklists.map((w) => w.fn)).toEqual(["erp_boms"]);
    expect(making.reports.map((r) => r.fn)).toEqual(["erp_works_orders"]);
    expect(stageDoors(making)).toContain("erp_works_orders");
  });

  test("/quality keeps Recalls and lists its events on the steps", () => {
    const quality = moduleAt("/quality");
    expect(quality.worklists.map((w) => w.fn)).toEqual(["erp_recalls"]);
    expect(stageDoors(quality)).toContain("erp_quality_events");
  });
});

/**
 * A panel's description belongs to one screen.
 *
 * Notifications' "Delivery, last seven days" described print queues, word for
 * word the Print queues panel's description on Output and printing, copied
 * with the panel (J-162). Two screens saying the same sentence about two
 * different things is a copy nobody finished; within one screen a description
 * may repeat, as the counting worklist's two dialogs do.
 */
describe("a panel's description is its own", () => {
  test("no description is said on two screens", () => {
    const root = join(import.meta.dir, "..", "..");
    const files: string[] = [];
    const walk = (dir: string) => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const path = join(dir, entry.name);
        if (entry.isDirectory()) walk(path);
        else if (entry.name.endsWith(".tsx") && !entry.name.includes(".test.")) files.push(path);
      }
    };
    walk(join(root, "src", "routes"));
    walk(join(root, "src", "components"));
    const where = new Map<string, Set<string>>();
    for (const file of files) {
      const src = readFileSync(file, "utf8");
      for (const m of src.matchAll(/description=(?:\{ui\(\s*)?"((?:[^"\\]|\\.)*)"/g)) {
        const said = m[1]!;
        where.set(said, (where.get(said) ?? new Set<string>()).add(file));
      }
    }
    // Guards the guard: a pattern that matched nothing would pass.
    expect(where.size).toBeGreaterThan(100);
    const shared = [...where]
      .filter(([, inFiles]) => inFiles.size > 1)
      .map(([said, inFiles]) => `${said.slice(0, 60)}… in ${[...inFiles].join(", ")}`);
    expect(shared).toEqual([]);
  });
});
