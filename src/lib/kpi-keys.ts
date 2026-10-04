import type { Kpi } from "./modules";

/**
 * One key per tile, each different.
 *
 * Two tiles may read the same door under the same label and say different
 * things about it: Purchasing's "Received, not yet billed" is both how many
 * lines and what they are worth. Keyed by door and label alone, React was
 * handed the same key twice. A repeat takes its place among its namesakes.
 */
export function kpiKeys(kpis: readonly Pick<Kpi, "fn" | "label">[]): string[] {
  const seen = new Map<string, number>();
  return kpis.map((k) => {
    const base = `${k.fn}-${k.label}`;
    const n = (seen.get(base) ?? 0) + 1;
    seen.set(base, n);
    return n === 1 ? base : `${base}-${n}`;
  });
}
