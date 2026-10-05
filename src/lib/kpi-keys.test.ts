import { describe, expect, test } from "bun:test";

import { kpiKeys } from "./kpi-keys";
import { MODULES, PURCHASING_KPIS, SALES_KPIS } from "./modules";

/**
 * Purchasing's page carried "Received, not yet billed" twice — how many lines,
 * and what they are worth — both read from erp_grni. The tiles were keyed by
 * door and label, so React was handed the same key twice. Every row of tiles
 * keys each tile differently, and both of those tiles stay, each now under
 * its own label (J-48).
 */
describe("every tile in a row has its own key", () => {
  const rows: [string, readonly { fn: string; label: string }[]][] = [
    ["sales", SALES_KPIS],
    ["purchasing", PURCHASING_KPIS],
    ...MODULES.map((m): [string, readonly { fn: string; label: string }[]] => [m.key, m.kpis]),
  ];

  for (const [name, kpis] of rows) {
    test(`${name}: no two tiles share a key`, () => {
      const keys = kpiKeys(kpis);
      expect(keys).toHaveLength(kpis.length);
      expect(new Set(keys).size).toBe(kpis.length);
    });
  }

  test("a tile with no namesake keeps the key it had", () => {
    expect(kpiKeys([{ fn: "erp_a", label: "A" }])).toEqual(["erp_a-A"]);
  });

  test("a repeat is numbered among its namesakes", () => {
    expect(
      kpiKeys([
        { fn: "erp_grni", label: "Received, not yet billed" },
        { fn: "erp_other", label: "Other" },
        { fn: "erp_grni", label: "Received, not yet billed" },
      ]),
    ).toEqual([
      "erp_grni-Received, not yet billed",
      "erp_other-Other",
      "erp_grni-Received, not yet billed-2",
    ]);
  });

  test("Purchasing keeps both of its received-not-billed tiles", () => {
    expect(PURCHASING_KPIS.filter((k) => k.fn === "erp_grni")).toHaveLength(2);
  });
});
