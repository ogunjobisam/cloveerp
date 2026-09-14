import type { ModuleDef } from "./modules";

/**
 * Figures about the product rather than about the organisation using it.
 *
 * erp_part5_summary measures the database against Part 5 of the foundation
 * specification — the product's own build progress. That is worth a platform
 * operator's glance and means nothing to a customer, who reads "Specification
 * coverage: 87%" as something wrong with their company. So the reads named
 * here are shown to platform operators and owners and left off for everybody
 * else: the figure, the chart and the report alike, and the catalogue that
 * lists reports by name.
 *
 * Hiding them is presentation. The read is harmless and stays callable.
 */
export const PLATFORM_READS: ReadonlySet<string> = new Set(["erp_part5_summary"]);

/** A module page as a customer sees it: without the platform's own figures. */
export function withoutPlatformReads(def: ModuleDef): ModuleDef {
  const { chart, ...rest } = def;
  return {
    ...rest,
    kpis: def.kpis.filter((k) => !PLATFORM_READS.has(k.fn)),
    reports: def.reports.filter((r) => !PLATFORM_READS.has(r.fn)),
    worklists: def.worklists.filter((w) => !PLATFORM_READS.has(w.fn)),
    ...(chart && !PLATFORM_READS.has(chart.fn) ? { chart } : {}),
  };
}

/** The module as this viewer sees it. */
export function moduleForViewer(def: ModuleDef, platformOperator: boolean): ModuleDef {
  return platformOperator ? def : withoutPlatformReads(def);
}
