/**
 * Suppliers' samples (20261004930000), as public.erp_samples answers them: a
 * supplier's goods lent for a shoot, a buying appointment, a press loan or a
 * fit check, held here as theirs until they go back, are kept or are bought.
 *
 * Settle is drawn on a row only where the database says the reader may decide
 * what becomes of it (procurement.order at its site) and something of it is
 * still held. The door refuses regardless.
 */

export type SamplePurpose = "shoot" | "buying" | "press" | "fit";

export type Sample = {
  lineId: string;
  receiptId: string;
  receiptNumber: string;
  supplier: string;
  itemCode: string;
  description: string;
  received: number;
  held: number;
  /** What became of the rest (J-15, 20261007061000), each net of any reversal. */
  returned: number;
  kept: number;
  bought: number;
  /** The price each was bought at, in minor units; null while none is bought. */
  boughtPriceMinor: number | null;
  purpose: SamplePurpose | null;
  dueBack: string | null;
  overdue: boolean;
  currency: string;
  maySettle: boolean;
};

type Row = Record<string, unknown>;

const asRecord = (v: unknown): Row | null =>
  typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Row) : null;

const finite = (v: unknown): number | null => {
  const n = Number(v);
  return v === null || v === undefined || v === "" || !Number.isFinite(n) ? null : n;
};

const text = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);

const PURPOSES: readonly SamplePurpose[] = ["shoot", "buying", "press", "fit"];

/** One row of erp_samples, or null when it is not one. */
export function sample(row: unknown): Sample | null {
  const r = asRecord(row);
  if (!r) return null;
  const lineId = text(r["line_id"]);
  const held = finite(r["held"]);
  if (lineId === null || held === null) return null;
  const purpose = r["purpose"];
  return {
    lineId,
    receiptId: text(r["receipt_id"]) ?? "",
    receiptNumber: text(r["receipt_number"]) ?? "",
    supplier: text(r["supplier"]) ?? "the supplier",
    itemCode: text(r["item_code"]) ?? "",
    description: text(r["description"]) ?? text(r["item_code"]) ?? "a sample",
    received: finite(r["received"]) ?? held,
    held,
    returned: finite(r["returned"]) ?? 0,
    kept: finite(r["kept"]) ?? 0,
    bought: finite(r["bought"]) ?? 0,
    boughtPriceMinor: finite(r["bought_price_minor"]),
    purpose: PURPOSES.includes(purpose as SamplePurpose) ? (purpose as SamplePurpose) : null,
    dueBack: text(r["due_back"]),
    overdue: r["overdue"] === true,
    currency: text(r["currency"]) ?? "GBP",
    maySettle: r["may_settle"] === true,
  };
}

/** Whether a row offers Settle: the database says the reader may, and something is still held. */
export function canSettle(s: Sample | null): s is Sample {
  return s !== null && s.maySettle && s.held > 0;
}

/** A quantity as the list shows it: whole numbers without their decimals. */
export function quantityWords(n: number): string {
  return Number.isInteger(n) ? String(n) : String(Number(n.toFixed(4)));
}
