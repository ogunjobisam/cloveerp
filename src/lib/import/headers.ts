import type { CsvRecord } from "./csv";
import type { Column, MappedRecord, Profile } from "./types";

/**
 * Which heading in the file is which column of the profile.
 *
 * Headings are compared after dropping case, spaces, punctuation and the
 * asterisk Xero puts on required columns, so "*ContactName", "Contact Name"
 * and "contact_name" are one heading. A mapping a person confirmed is kept by
 * heading text, so the next export from the same system maps itself.
 *
 * Report exports (aged ledgers, trial balance) carry title lines above the
 * headings — the organisation's name, the report's name, "As at 30 September
 * 2026" — so the heading row is found, not assumed to be the first.
 */

export function normaliseHeading(text: string): string {
  return text.toLowerCase().replace(/[^a-z0-9]/g, "");
}

/** Column key → the index of the heading it reads, or null for none. */
export type Mapping = Record<string, number | null>;

/** Column key → heading text, as remembered between files. */
export type SavedMapping = Record<string, string>;

function namesOf(column: Column): string[] {
  return [column.key, column.label, ...column.aliases].map(normaliseHeading);
}

export function autoMap(
  headings: readonly string[],
  columns: readonly Column[],
  saved?: SavedMapping | null,
): Mapping {
  const normal = headings.map(normaliseHeading);
  const used = new Set<number>();
  const mapping: Mapping = {};

  // A remembered choice wins over a guess, where the heading is still there.
  for (const column of columns) {
    const text = saved?.[column.key];
    if (text === undefined) continue;
    const at = normal.indexOf(normaliseHeading(text));
    if (at >= 0 && !used.has(at)) {
      mapping[column.key] = at;
      used.add(at);
    }
  }
  for (const column of columns) {
    if (mapping[column.key] !== undefined) continue;
    const names = namesOf(column);
    const at = normal.findIndex((h, i) => !used.has(i) && h !== "" && names.includes(h));
    mapping[column.key] = at >= 0 ? at : null;
    if (at >= 0) used.add(at);
  }
  return mapping;
}

export function missingRequired(mapping: Mapping, columns: readonly Column[]): Column[] {
  return columns.filter((c) => c.required && (mapping[c.key] ?? null) === null);
}

export function unusedHeadings(mapping: Mapping, headings: readonly string[]): string[] {
  const used = new Set(Object.values(mapping).filter((v): v is number => v !== null));
  return headings.filter((h, i) => !used.has(i) && h.trim() !== "");
}

export function toSaved(mapping: Mapping, headings: readonly string[]): SavedMapping {
  const saved: SavedMapping = {};
  for (const [key, at] of Object.entries(mapping)) {
    const text = at === null ? undefined : headings[at];
    if (text !== undefined) saved[key] = text;
  }
  return saved;
}

/**
 * The index of the heading row: the first of the opening lines that names
 * the most of the profile's columns. A file whose first line is its headings
 * returns 0, as a contacts export does.
 */
export function findHeaderRow(records: readonly CsvRecord[], profile: Profile, scan = 20): number {
  if (!profile.findsHeaderRow) return 0;
  let best = 0;
  let bestScore = 0;
  const limit = Math.min(scan, records.length);
  for (let i = 0; i < limit; i++) {
    const fields = records[i]?.fields ?? [];
    const score = profile.columns.filter((c) => {
      const names = namesOf(c);
      return fields.some((f) => names.includes(normaliseHeading(f)));
    }).length;
    if (score > bestScore) {
      best = i;
      bestScore = score;
    }
  }
  return best;
}

export type Split = {
  headings: string[];
  body: CsvRecord[];
  /** Lines whose field count differs from the headings'. */
  ragged: number[];
};

export function splitAtHeader(records: readonly CsvRecord[], headerAt: number): Split {
  const headings = (records[headerAt]?.fields ?? []).map((h) => h.trim());
  const body = records.slice(headerAt + 1);
  const ragged = body
    .filter((r) => r.fields.length !== headings.length && r.fields.some((f) => f.trim() !== ""))
    .map((r) => r.line);
  return { headings, body, ragged };
}

export function applyMapping(body: readonly CsvRecord[], mapping: Mapping): MappedRecord[] {
  return body
    .filter((r) => r.fields.some((f) => f.trim() !== ""))
    .map((r) => {
      const values: Record<string, string> = {};
      for (const [key, at] of Object.entries(mapping)) {
        if (at !== null) values[key] = r.fields[at] ?? "";
      }
      return { line: r.line, values };
    });
}
