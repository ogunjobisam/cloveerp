import { describe, expect, test } from "bun:test";

import { emptySession, type ErpSession } from "./erp";
import { tileOffered } from "./installed-modules";
import { AREA_HOME, GROUP_LABELS, allTiles, areaOf, type TileDef } from "./modules";
import { railParent, trailFor } from "./rail";

/**
 * The Work rail folds a screen under the screen of its own group whose path
 * holds it, and the trail files a path by the same rule (J-130). Nothing
 * folded is lost: every screen still has a way to it on the rail, and every
 * screen's trail starts in the area its rail entry is in.
 */

const onRail = allTiles().filter((t) => !t.offRail);

function session(modules?: string[]): ErpSession {
  const all = allTiles()
    .flatMap((t) => (t.permission === undefined ? [] : [t.permission].flat()))
    .filter((p, i, a) => a.indexOf(p) === i);
  return { ...emptySession, permissions: all, ...(modules ? { modules } : {}) };
}

/** The Work rail's entries for these tiles: Home, then every entry at the top of its group. */
function workEntries(tiles: readonly TileDef[]): number {
  const work = tiles.filter((t) => !t.offRail && areaOf(t.group) === "work");
  return 1 + work.filter((t) => railParent(t.path, work) === null).length;
}

describe("the rail folds a sub-screen under its parent", () => {
  test("exactly these eleven screens fold, each under the screen of its own group", () => {
    const folded = onRail
      .flatMap((t) => {
        const parent = railParent(t.path, onRail);
        return parent === null ? [] : [`${t.path} -> ${parent}`];
      })
      .sort();
    expect(folded).toEqual([
      "/finance/close -> /finance",
      "/finance/journals -> /finance",
      "/finance/reconciliation -> /finance",
      "/finance/statements -> /finance",
      "/finance/vat -> /finance",
      "/inventory/adjustments -> /inventory",
      "/inventory/audit -> /inventory",
      "/inventory/transfers -> /inventory",
      "/master-data/imports -> /master-data",
      "/reporting/distribution -> /reporting",
      "/reporting/reproducibility -> /reporting",
    ]);
  });

  test("a screen never folds under another group's screen", () => {
    for (const t of onRail) {
      const parent = railParent(t.path, onRail);
      if (parent === null) continue;
      expect(onRail.find((p) => p.path === parent)?.group).toBe(t.group);
    }
    expect(railParent("/inventory/forecast", onRail)).toBeNull();
    expect(railParent("/inventory/warehouse", onRail)).toBeNull();
    expect(railParent("/finance/dimensions", onRail)).toBeNull();
  });

  test("a screen whose parent is not offered stays at the top of its group", () => {
    const withoutFinancials = onRail.filter((t) => t.path !== "/finance");
    expect(railParent("/finance/close", withoutFinancials)).toBeNull();
  });

  test("Settings has nothing to fold", () => {
    const settings = onRail.filter((t) => areaOf(t.group) === "settings");
    expect(settings.filter((t) => railParent(t.path, settings) !== null)).toEqual([]);
  });

  test("the Work rail is 16 entries on the platform, 14 for a customer, 11 in the demonstration", () => {
    const all = allTiles();
    const platform = all.filter((t) => tileOffered(t, session(), true));
    const customer = all.filter((t) => tileOffered(t, session(), false));
    const demonstration = all.filter((t) =>
      tileOffered(
        t,
        session(["finance", "inventory", "logistics", "master_data", "procurement", "sales"]),
        false,
      ),
    );
    const flat = (tiles: TileDef[]) =>
      1 + tiles.filter((t) => !t.offRail && areaOf(t.group) === "work").length;
    expect([flat(platform), flat(customer), flat(demonstration)]).toEqual([27, 25, 22]);
    expect([workEntries(platform), workEntries(customer), workEntries(demonstration)]).toEqual([
      16, 14, 11,
    ]);
  });

  test("every folded screen's parent is on the same rail, so the toggle reaches it", () => {
    for (const modules of [undefined, ["finance", "inventory", "sales"]]) {
      const offered = allTiles().filter(
        (t) => !t.offRail && tileOffered(t, session(modules), false),
      );
      for (const t of offered) {
        const parent = railParent(t.path, offered);
        if (parent !== null) expect(offered.some((p) => p.path === parent)).toBe(true);
      }
    }
  });
});

describe("the trail files a screen where the rail does", () => {
  test("every rail screen's trail starts at its area's home, then names its group", () => {
    for (const t of onRail) {
      const trail = trailFor(t.path);
      expect({ path: t.path, root: trail[0]?.to }).toEqual({
        path: t.path,
        root: AREA_HOME[areaOf(t.group)],
      });
      expect({ path: t.path, group: trail[1] }).toEqual({
        path: t.path,
        group: { to: null, label: GROUP_LABELS[t.group] },
      });
      expect(trail.at(-1)).toEqual({ to: t.path, label: t.title });
    }
  });

  test("a folded screen's trail passes through the screen it folds under", () => {
    for (const t of onRail) {
      const parent = railParent(t.path, onRail);
      const screens = trailFor(t.path)
        .slice(2)
        .map((c) => c.to);
      expect({ path: t.path, screens }).toEqual({
        path: t.path,
        screens: parent === null ? [t.path] : [parent, t.path],
      });
    }
  });

  test("a screen kept off the rail starts at Home and names no group", () => {
    for (const t of allTiles().filter((x) => x.offRail)) {
      expect(trailFor(t.path)).toEqual([
        { to: "/", label: "Home" },
        { to: t.path, label: t.title },
      ]);
    }
  });

  test("J-130: Warehouse layout is under Products and places, not Stock", () => {
    expect(trailFor("/inventory/warehouse").map((c) => c.label)).toEqual([
      "Settings",
      "Products and places",
      "Warehouse layout",
    ]);
    expect(trailFor("/inventory/forecast").map((c) => c.label)).toEqual([
      "Home",
      "Plan",
      "Stock forecast",
    ]);
  });

  test("anything below a screen keeps its segment, and an identifier takes its name", () => {
    expect(trailFor("/finance/journals/new")).toEqual([
      { to: "/", label: "Home" },
      { to: null, label: "Settle" },
      { to: "/finance", label: "Financials" },
      { to: "/finance/journals", label: "Journals" },
      { to: "/finance/journals/new", label: "New" },
    ]);
    expect(trailFor("/documents/abc", { "/documents/abc": "SO-000001" }).at(-1)).toEqual({
      to: "/documents/abc",
      label: "SO-000001",
    });
    expect(trailFor("/settings/anything")[0]).toEqual({ to: "/settings", label: "Settings" });
    expect(trailFor("/")).toEqual([{ to: "/", label: "Home" }]);
  });
});
