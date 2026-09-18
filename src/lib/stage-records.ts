import { prettifyField } from "./friendly";
import { formatMinor } from "./money";

/**
 * What sits at a step of a process strip, and what the record on the right says.
 *
 * Walking the demo organisation's Purchasing screen on 14 September, step
 * "1 Requisition (26)" listed requisitions already Ordered and "2 Approval
 * (26)" listed the same twenty-six: a step listed every document of its type,
 * not the documents waiting there. The record beside the list printed the
 * read's columns as they came — STATE ordered, TOTAL MINOR 317100, IS
 * CANCELLED false — and offered "Submit for approval" on a requisition that had
 * been turned into an order a week before.
 *
 * Everything here is a plain function over rows, so the rules can be tested
 * without a screen: which rows sit at a step, which verbs a record is offered,
 * and which of its fields a person reads.
 */

export type Row = Record<string, unknown>;

/** The read every document step lists from. */
export const DOCUMENT_READ = "erp_documents";

/**
 * States in which a record has finished its process.
 *
 * Tenants configure their own lifecycles, so this is the product's words for
 * finished rather than a list the database keeps. It decides two things only:
 * which rows "Show finished" brings back, and which verbs are greyed on a
 * record that is not in one of its step's own states.
 */
export const SETTLED: ReadonlySet<string> = new Set([
  "done",
  "complete",
  "completed",
  "posted",
  "closed",
  "permanently_closed",
  "cancelled",
  "canceled",
  "rejected",
  "delivered",
  "despatched",
  "dispatched",
  "received",
  "paid",
  "withdrawn",
  "superseded",
  "archived",
  "ordered",
  "accepted",
  "declined",
  "expired",
  "credited",
  "converted",
]);

/**
 * The state code of a row.
 *
 * A document carries its code as `state` and its display name as
 * `state_name`; every other stage read carries one `status`. The code is what
 * a step's states are written in, so it is read first.
 */
export function stateOf(row: Row | null | undefined, statusKey?: string): string | null {
  if (!row) return null;
  const keys = ["state", statusKey, "status", "task_status", "document_state"];
  for (const key of keys) {
    if (!key) continue;
    const value = row[key];
    if (typeof value === "string" && value.trim() !== "") return value.trim().toLowerCase();
  }
  return null;
}

/** A row that has finished: cancelled on the record itself, or in a finished state. */
export function isFinished(row: Row, statusKey?: string): boolean {
  if (row["is_cancelled"] === true) return true;
  const state = stateOf(row, statusKey);
  return state !== null && SETTLED.has(state);
}

/**
 * The arguments a step's read is called with.
 *
 * A document step asks the door for its states (public.erp_documents'
 * p_states, 20260914050000), so its limit is spent on documents that are
 * there rather than on history. Asked for finished ones too, it reads the type
 * whole and the rows are narrowed by `rowsAtStage`, because the door leaves a
 * cancelled document out of any filtered read.
 */
export function stageReadArgs(
  fn: string,
  args: Record<string, unknown>,
  states: readonly string[] | undefined,
  showFinished: boolean,
): Record<string, unknown> {
  if (fn !== DOCUMENT_READ || !states || states.length === 0 || showFinished) return args;
  return { ...args, p_states: [...states] };
}

/**
 * The rows sitting at a step: in one of its states, and — when asked — the
 * finished ones beside them. A step that names no states lists its read as
 * it comes.
 */
export function rowsAtStage(
  rows: Row[],
  step: { states?: readonly string[] | undefined; statusKey?: string | undefined },
  showFinished = false,
): Row[] {
  const states = step.states;
  if (!states || states.length === 0) return rows;
  return rows.filter((row) => {
    const state = stateOf(row, step.statusKey);
    const here = state !== null && states.includes(state) && row["is_cancelled"] !== true;
    return here || (showFinished && isFinished(row, step.statusKey));
  });
}

/**
 * The state a record is already in, when its verbs should be greyed for it.
 *
 * A record in one of its step's own states is not settled at that step,
 * whatever the word: a despatched shipment is exactly what the proof step is
 * for.
 */
export function settledAtStage(
  row: Row | null,
  statusKey: string | undefined,
  states: readonly string[] | undefined,
): string | null {
  if (!row) return null;
  const state = stateOf(row, statusKey);
  if (state !== null && states?.includes(state)) return null;
  if (row["is_cancelled"] === true) return "cancelled";
  return state !== null && SETTLED.has(state) ? state : null;
}

/** How one verb is drawn against the chosen record. */
export type Offer = "offer" | "hide" | "wait" | "settled";

/**
 * Whether a verb is offered on the chosen record.
 *
 *   - A verb that performs a transition is offered only when the record's
 *     current state has that transition. `available` is the codes the
 *     database says are available (erp_document's available_transitions):
 *     `undefined` while that read is still coming, `null` when there is no
 *     such read for this record, in which case the step's own states answer.
 *   - A verb a step offers only in some states — converting an approved
 *     requisition, billing a posted receipt — is offered in those.
 *   - Any other verb stays, greyed on a record that has already finished.
 *
 * This is never the enforcement. The database refuses a move that is not
 * there whatever the screen offers; this is only about not offering it.
 */
export function offerFor(input: {
  transition?: string | undefined;
  offeredIn?: readonly string[] | undefined;
  state: string | null;
  stageStates?: readonly string[] | undefined;
  available: readonly string[] | null | undefined;
  settled: boolean;
  staysOpen: boolean;
}): Offer {
  if (input.transition) {
    if (input.available === undefined) return "wait";
    if (input.available === null) {
      if (!input.stageStates || input.stageStates.length === 0) return "offer";
      return input.state !== null && input.stageStates.includes(input.state) ? "offer" : "hide";
    }
    return input.available.includes(input.transition) ? "offer" : "hide";
  }
  if (input.offeredIn) {
    return input.state !== null && input.offeredIn.includes(input.state) ? "offer" : "hide";
  }
  if (input.settled && !input.staysOpen) return "settled";
  return "offer";
}

/** One line of the record panel. */
export type RecordField = {
  key: string;
  label: string;
  value: string;
  kind: "text" | "money" | "date" | "number" | "flag";
};

/**
 * The words a record's fields are shown under, where the column's own name is
 * not how anyone says it. Every one has an erp_ref.resource row
 * (20260914073000), so an organisation can rename it.
 */
export const FIELD_LABELS: Readonly<Record<string, string>> = {
  party: "Business partner",
  document_date: "Document date",
  required_date: "Required by",
  total_minor: "Total",
  // Total keeps its meaning — the net the approval bands and the credit check
  // are about — and the tax sits beside it (20260916030000).
  tax_minor: "Tax",
  gross_minor: "Total with tax",
};

/**
 * What the party on a document is called, from the side of the trade the step
 * is on: a sales step's documents name a customer, a purchasing step's a
 * supplier, and a step that does not say names a business partner.
 */
export function partyLabel(partyRole: string | undefined): string {
  if (partyRole === "customer") return "Customer";
  if (partyRole === "supplier") return "Supplier";
  return FIELD_LABELS["party"] ?? "Business partner";
}

/** Fields a document's record shows, in this order. Its number and state head the panel. */
const DOCUMENT_FIELDS = [
  "party",
  "document_date",
  "required_date",
  "total_minor",
  "tax_minor",
  "gross_minor",
];

/**
 * Fields a document shows only when it has them. A required date belongs to an
 * order and not to an invoice; tax and the gross belong to a document that
 * carries tax, and erp_document leaves both keys out where there is none, so a
 * document without tax reads exactly as it did before.
 */
const DOCUMENT_FIELDS_WHEN_PRESENT = new Set(["required_date", "tax_minor", "gross_minor"]);

const TIMESTAMP = /^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})/;
const DATE = /^\d{4}-\d{2}-\d{2}$/;

/** A date as the database's own order, and a time to the minute. */
export function formatWhen(value: string): string {
  const stamp = TIMESTAMP.exec(value);
  if (stamp) return stamp[2] === "00:00" ? stamp[1]! : `${stamp[1]} ${stamp[2]}`;
  return value;
}

function labelFor(key: string, partyRole?: string): string {
  if (key === "party") return partyLabel(partyRole);
  const known = FIELD_LABELS[key];
  if (known) return known;
  return prettifyField(key.replace(/_minor$/, ""));
}

/** Whether a column is the machinery rather than the record: flags, keys, nested reads. */
export function isInternalField(key: string, value: unknown): boolean {
  if (key.startsWith("is_") || key.endsWith("_id") || key === "id") return true;
  return value !== null && typeof value === "object";
}

function fieldOf(
  key: string,
  value: unknown,
  row: Row,
  minorUnits: (code: string) => number,
  partyRole?: string,
): RecordField {
  const label = labelFor(key, partyRole);
  if (value === null || value === undefined || value === "")
    return { key, label, value: "—", kind: "text" };
  if (key.endsWith("_minor")) {
    const n = Number(value);
    const code = typeof row["currency"] === "string" && row["currency"] ? row["currency"] : "GBP";
    return Number.isFinite(n)
      ? { key, label, value: formatMinor(n, code, minorUnits(code)), kind: "money" }
      : { key, label, value: String(value), kind: "text" };
  }
  if (typeof value === "boolean") return { key, label, value: value ? "Yes" : "No", kind: "flag" };
  if (typeof value === "number") return { key, label, value: String(value), kind: "number" };
  const text = String(value);
  if (DATE.test(text) || TIMESTAMP.test(text))
    return { key, label, value: formatWhen(text), kind: "date" };
  return { key, label, value: text, kind: "text" };
}

/**
 * What the record panel shows of a row.
 *
 * A document shows its customer or supplier, its dates and its total as money; its number
 * and its state head the panel, and nothing else of the read is the reader's
 * business. Any other step's row shows its columns less the machinery: no
 * identifiers, no `is_` flags, no nested reads, the state only as the pill,
 * amounts in minor units as money, and the currency only where no amount
 * already carries it.
 */
export function summariseRecord(
  row: Row,
  source: { fn: string; id: string; title?: readonly string[]; status?: string | undefined },
  minorUnits: (code: string) => number = () => 2,
  partyRole?: string,
): RecordField[] {
  if (source.fn === DOCUMENT_READ) {
    return DOCUMENT_FIELDS.filter((k) => !DOCUMENT_FIELDS_WHEN_PRESENT.has(k) || row[k]).map((k) =>
      fieldOf(k, row[k], row, minorUnits, partyRole),
    );
  }

  const hasMoney = Object.keys(row).some((k) => k.endsWith("_minor"));
  const skip = new Set<string>([source.id, ...(source.title ?? [])]);
  if (source.status) skip.add(source.status);
  if ("state_name" in row) skip.add("state");

  return Object.entries(row)
    .filter(([k, v]) => !skip.has(k) && !isInternalField(k, v))
    .filter(([k]) => !(k === "currency" && hasMoney))
    .map(([k, v]) => fieldOf(k, v, row, minorUnits));
}

/** A document line, as erp_document returns it. */
export type DocumentLine = {
  line_no: number;
  item: string | null;
  description: string | null;
  quantity: number;
  net_minor: number | null;
  /** Null on every line until the document commits and its tax is determined. */
  tax_minor?: number | null;
  tax_rate_pct?: number | string | null;
};

/** One line of a document, in a sentence's worth of words. */
export function describeLine(line: DocumentLine): string {
  const what = [line.item, line.description].filter((x) => x && String(x).trim() !== "");
  return what.length > 0 ? what.join(" — ") : `#${line.line_no}`;
}

/**
 * How many steps of a strip go on one row.
 *
 * Purchasing's eight steps at 1512 pixels rendered step 3 as "Purchas…", step 7
 * as "Supplier…", and step 8 — Payment — off the right edge with nothing to say
 * it was there. A step nobody can read is not a step, and one nobody can see is
 * worse. So a strip is never narrower per step than its names need: when every
 * step fits, it is one row; when they do not, it wraps, and the rows are made
 * even — eight steps that fit six to a row go four and four, not six and two,
 * because a row of two reads as an afterthought and the last step of a process
 * is usually the one that matters most.
 *
 * `fits` is how many steps the width available can hold side by side.
 */
export function stepsPerRow(count: number, fits: number): number {
  if (count <= 0) return 1;
  const room = Math.max(1, Math.floor(fits));
  if (room >= count) return count;
  const rows = Math.ceil(count / room);
  return Math.ceil(count / rows);
}
