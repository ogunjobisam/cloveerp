import type { AccountResolution, ProfileContext } from "./types";

/**
 * The crosswalk as erp_import_crosswalk answers it: a legacy key and the Clove
 * code it resolves to, from loaded batches only. A batch rolled back takes its
 * entries with it, so nothing here outlives the import that said it.
 */

export type CrosswalkEntry = {
  legacy_key: string;
  legacy_name: string | null;
  clove_code: string;
  resolution: "map" | "create" | "control";
};

const norm = (text: string) => text.trim().toLowerCase();

/** Legacy name → party code, for the ledgers that name parties by name. */
export function partyKeysFrom(entries: readonly CrosswalkEntry[]): Record<string, string> {
  const keys: Record<string, string> = {};
  // A name is a key where no entry uses it as one: Unleashed's lists are keyed
  // by code, and a product names its supplier by either.
  for (const e of entries)
    if (e.legacy_name && !(e.legacy_name in keys)) keys[e.legacy_name] = e.clove_code;
  for (const e of entries) keys[e.legacy_key] = e.clove_code;
  return keys;
}

/**
 * A legacy account resolved by its code, or by its name where the report
 * prints none — the trial balance's "Suspense" is found by the name the chart
 * loaded it under.
 */
export function accountResolver(entries: readonly CrosswalkEntry[]): ProfileContext["account"] {
  const byKey = new Map<string, AccountResolution>();
  const byName = new Map<string, AccountResolution>();
  for (const e of entries) {
    const r = { code: e.clove_code, control: e.resolution === "control" };
    byKey.set(norm(e.legacy_key), r);
    if (e.legacy_name) byName.set(norm(e.legacy_name), r);
  }
  return (legacyCode, name) =>
    (legacyCode !== null ? byKey.get(norm(legacyCode)) : undefined) ??
    byKey.get(norm(name)) ??
    byName.get(norm(name)) ??
    null;
}
