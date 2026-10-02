/**
 * Landed costs (20261004970000), as public.erp_landed_costs answers them: a
 * supplier's bill for a charge on a goods receipt, and what of it landed on
 * the goods still held and what stayed a cost of sales.
 */

export type LandedCost = {
  id: string;
  billId: string | null;
  bill: string;
  receiptId: string | null;
  receipt: string;
  supplier: string;
  charge: string;
  amountMinor: number;
  currency: string;
  /** Null until the bill has registered and the charge has been placed. */
  capitalisedMinor: number | null;
  expensedMinor: number | null;
};

type Row = Record<string, unknown>;

const asRecord = (v: unknown): Row | null =>
  typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Row) : null;

const text = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);

const minor = (v: unknown): number | null =>
  typeof v === "number" && Number.isFinite(v) ? v : null;

/** One row of erp_landed_costs, or null when it is not one. */
export function landedCost(row: unknown): LandedCost | null {
  const r = asRecord(row);
  const id = text(r?.["landed_cost_id"]);
  if (r === null || id === null) return null;
  return {
    id,
    billId: text(r["bill_id"]),
    bill: text(r["bill"]) ?? "",
    receiptId: text(r["receipt_id"]),
    receipt: text(r["receipt"]) ?? "",
    supplier: text(r["supplier"]) ?? "",
    charge: text(r["charge_code"]) ?? "other",
    amountMinor: minor(r["amount_minor"]) ?? 0,
    currency: text(r["currency"]) ?? "GBP",
    capitalisedMinor: minor(r["capitalised_minor"]),
    expensedMinor: minor(r["expensed_minor"]),
  };
}

/** Every row of the answer that is one, newest first as the database ordered them. */
export function landedCosts(result: unknown): LandedCost[] {
  return (Array.isArray(result) ? result : [])
    .map(landedCost)
    .filter((c): c is LandedCost => c !== null);
}

/** A charge in the words its choice reads in. */
export function chargeWords(charge: string): string {
  const words: Record<string, string> = {
    duty: "Duty",
    brokerage: "Brokerage",
    insurance: "Insurance",
    handling: "Handling",
    freight: "Freight",
  };
  return words[charge] ?? "Other";
}
