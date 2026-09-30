import { parseCsv } from "./csv";
import {
  applyMapping,
  autoMap,
  findHeaderRow,
  missingRequired,
  splitAtHeader,
  unusedHeadings,
  type Mapping,
  type SavedMapping,
} from "./headers";
import type { Column, Exclusion, Finding, Profile, ProfileContext, ProfileResult } from "./types";
import { addDecimals, decimalText, deriveCode, parseDecimal } from "./values";

/**
 * A file, read end to end against one profile. Pure: the screen holds the
 * state, this says what the file is.
 */

export type FileRead = {
  headings: string[];
  headerLine: number | null;
  mapping: Mapping;
  missing: Column[];
  unused: string[];
  /** File-level problems: an unclosed quote, ragged lines. */
  findings: Finding[];
  /** Null while a required column is unmapped: there is nothing to transform. */
  result: ProfileResult | null;
};

export function readFile(
  text: string,
  profile: Profile,
  ctx: ProfileContext,
  choice: { mapping?: Mapping | null; saved?: SavedMapping | null } = {},
): FileRead {
  const parsed = parseCsv(text);
  const findings: Finding[] = [];
  if (parsed.unterminatedAt !== null) {
    findings.push({
      line: parsed.unterminatedAt,
      severity: "error",
      message: "a quote opened here is never closed, so the rest of the file reads as one value",
    });
  }
  const headerAt = findHeaderRow(parsed.records, profile);
  const { headings, body, ragged } = splitAtHeader(parsed.records, headerAt);
  for (const line of ragged) {
    findings.push({
      line,
      severity: "warning",
      message: "this line has a different number of values from the headings",
    });
  }
  const mapping = choice.mapping ?? autoMap(headings, profile.columns, choice.saved ?? null);
  const missing = missingRequired(mapping, profile.columns);
  const result =
    missing.length === 0 && parsed.unterminatedAt === null
      ? profile.transform(applyMapping(body, mapping), ctx)
      : null;
  return {
    headings,
    headerLine: parsed.records[headerAt]?.line ?? null,
    mapping,
    missing,
    unused: unusedHeadings(mapping, headings),
    findings,
    result,
  };
}

/** Party resolution from names kept from contacts files staged earlier. */
export function partyResolver(keys: Readonly<Record<string, string>>): ProfileContext["partyCode"] {
  const byLower = new Map(Object.entries(keys).map(([k, v]) => [k.trim().toLowerCase(), v]));
  return (name) => {
    const known = byLower.get(name.trim().toLowerCase());
    return known !== undefined
      ? { code: known, known: true }
      : { code: deriveCode(name, new Set()), known: false };
  };
}

/**
 * The control figure: what the printed report said, less what was held back.
 * The printed figure is typed by a person; the exclusions are listed beside
 * it, so the figure is never computed from the file alone.
 */
export function controlFigure(printedMinor: number, exclusions: readonly Exclusion[]): number {
  return exclusions.reduce((sum, e) => sum - (e.amountMinor ?? 0), printedMinor);
}

export function controlQuantity(printed: string, exclusions: readonly Exclusion[]): string | null {
  const p = parseDecimal(printed);
  if (!p) return null;
  const out = exclusions
    .map((e) => (e.quantity === null ? null : parseDecimal(e.quantity)))
    .filter((d) => d !== null)
    .map((d) => ({ units: -d.units, scale: d.scale }));
  return decimalText(addDecimals([p, ...out]));
}
