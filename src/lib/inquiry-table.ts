/**
 * How an inquiry's answer is laid out, decided apart from the drawing so it
 * can be tested.
 *
 * The inquiries answer JSON documents, not uniform rows, so the screen draws
 * whatever comes back. Three things it drew badly (J-109, J-92, J-105):
 *
 *   - Identifiers. ITEM SUPPLIER ID, PARTY ID, SITE ID and VALUE ID were
 *     printed as raw UUIDs: the door answers them for its own callers, and
 *     nobody reading the screen can do anything with one.
 *   - Lists of rows. "Supply and demand" answered a row per day and each was
 *     drawn as its own card of labels, so a projection read as a stack of
 *     forms rather than as a table you can run your eye down.
 *   - Dates, printed as the database writes them.
 */

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE =
  /^\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}(?::?\d{2})?)?)?$/;

/**
 * A key ending in _id that holds a UUID, or nothing: an identifier, not
 * something to read. A key ending in _id that holds words is shown.
 */
export function isIdentifier(key: string, value: unknown): boolean {
  if (!key.endsWith("_id")) return false;
  return value === null || (typeof value === "string" && UUID.test(value));
}

/** The fields of an answer worth showing: every one but its identifiers. */
export function shownEntries(record: Record<string, unknown>): [string, unknown][] {
  return Object.entries(record).filter(([k, v]) => !isIdentifier(k, v));
}

/** A field's name as a heading: amount_minor reads "amount", due_on "due on". */
export function fieldHeading(key: string): string {
  return key.replace(/_minor$/, "").replace(/_/g, " ");
}

/** How one value is drawn: as money, as a date, or as itself. */
export type CellKind = "money" | "date" | "value";

export function cellKind(key: string, value: unknown): CellKind {
  if (key.endsWith("_minor") && typeof value === "number" && Number.isFinite(value)) return "money";
  if (typeof value === "string" && DATE.test(value)) return "date";
  return "value";
}

/** The currency an answer's amounts are in: its own where it says one. */
export function currencyOf(record: Record<string, unknown>): string {
  const c = record["currency"];
  return typeof c === "string" && c !== "" ? c : "GBP";
}

/** An answer with nothing in it: an empty list, or no answer at all. */
export function isEmptyAnswer(value: unknown): boolean {
  return value === null || value === undefined || (Array.isArray(value) && value.length === 0);
}

export type InquiryTable = {
  columns: { key: string; heading: string }[];
  rows: Record<string, unknown>[];
};

function isFlatRecord(value: unknown): value is Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  return Object.values(value).every((v) => v === null || typeof v !== "object");
}

/**
 * A list of rows that share their fields, as a table; anything else, null.
 *
 * Only flat rows with the same fields in each: a row holding a list or a
 * record of its own does not fit a cell, and rows that differ are not one
 * table. A column of identifiers is left out, as a field of them is.
 */
export function asTable(value: unknown): InquiryTable | null {
  if (!Array.isArray(value) || value.length === 0) return null;
  if (!value.every(isFlatRecord)) return null;
  const rows = value as Record<string, unknown>[];
  const keys = Object.keys(rows[0] ?? {});
  if (keys.length === 0) return null;
  const same = (r: Record<string, unknown>) => {
    const k = Object.keys(r);
    return (
      k.length === keys.length && keys.every((x) => Object.prototype.hasOwnProperty.call(r, x))
    );
  };
  if (!rows.every(same)) return null;
  const columns = keys
    .filter((k) => !rows.every((r) => isIdentifier(k, r[k])))
    .map((key) => ({ key, heading: fieldHeading(key) }));
  if (columns.length === 0) return null;
  return { columns, rows };
}
