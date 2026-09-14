import { describe, expect, test } from "bun:test";

import { REPORTING } from "./modules";
import { PLATFORM_READS, moduleForViewer, withoutPlatformReads } from "./platform-reads";

const reads = (def: typeof REPORTING) => [
  ...def.kpis.map((k) => k.fn),
  ...def.reports.map((r) => r.fn),
  ...def.worklists.map((w) => w.fn),
  ...(def.chart ? [def.chart.fn] : []),
];

describe("the specification's own figures", () => {
  test("are on Reports and inquiries for the platform to see", () => {
    expect(reads(REPORTING)).toContain("erp_part5_summary");
    expect(moduleForViewer(REPORTING, true)).toBe(REPORTING);
  });

  test("are gone for a customer: no figure, no chart, no report", () => {
    const seen = moduleForViewer(REPORTING, false);
    for (const fn of reads(seen)) expect(PLATFORM_READS.has(fn)).toBe(false);
    expect(seen.chart).toBeUndefined();
    expect(seen.kpis.map((k) => k.label)).not.toContain("Specification coverage");
    expect(seen.reports.map((r) => r.title)).not.toContain("Specification coverage");
  });

  test("take nothing else with them", () => {
    const seen = withoutPlatformReads(REPORTING);
    expect(seen.kpis.length).toBe(
      REPORTING.kpis.filter((k) => k.fn !== "erp_part5_summary").length,
    );
    expect(seen.reports.map((r) => r.title)).toContain("Business partner data quality");
    expect(seen.worklists).toEqual(REPORTING.worklists);
    expect(seen.title).toBe(REPORTING.title);
    expect(seen.path).toBe(REPORTING.path);
  });
});
