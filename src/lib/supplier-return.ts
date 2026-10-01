import { formatMinor } from "./money";
import type { Outcome } from "./plain-words";

/**
 * Goods sent back to a supplier (20261004910000): a return for credit, whose
 * credit pays the bill it credits, or for replacement, which credits nothing
 * and awaits the same goods again.
 *
 * A return is what public.erp_supplier_return answers; a row of Supplier
 * credit notes is what public.erp_supplier_credit_notes answers; an allocation
 * by hand is what public.erp_allocate_supplier_credit answers.
 *
 * The screens draw Receive the replacement only where the database says the
 * reader may (procurement.receive on an issued return for replacement that
 * still awaits something), and Allocate only where it says the reader may
 * allocate (finance.post) and names an open bill to take the credit. The doors
 * refuse regardless.
 */

export type SupplierReturn = {
  returnId: string;
  outcome: "credit" | "replacement";
  rma: string | null;
  currency: string;
  creditLeftMinor: number;
  awaited: number;
  mayReceive: boolean;
  receipts: { documentId: string; number: string }[];
};

export type SupplierCreditBill = { documentId: string; number: string; owesMinor: number };

export type SupplierCredit = {
  creditNoteId: string;
  creditNoteNumber: string;
  supplier: string;
  currency: string;
  leftMinor: number;
  allocatable: boolean;
  bills: SupplierCreditBill[];
};

type Row = Record<string, unknown>;

const asRecord = (v: unknown): Row | null =>
  typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Row) : null;

const finite = (v: unknown): number | null => {
  const n = Number(v);
  return v === null || v === undefined || v === "" || !Number.isFinite(n) ? null : n;
};

const text = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);

/** What erp_supplier_return answered, or null when it is not a supplier return. */
export function supplierReturn(result: unknown): SupplierReturn | null {
  const r = asRecord(result);
  if (!r) return null;
  const returnId = text(r["return_id"]);
  if (returnId === null) return null;
  const receipts = Array.isArray(r["receipts"])
    ? r["receipts"].map(asRecord).flatMap((x) => {
        const documentId = text(x?.["document_id"]);
        return documentId !== null
          ? [{ documentId, number: text(x?.["document_number"]) ?? "a receipt" }]
          : [];
      })
    : [];
  return {
    returnId,
    outcome: r["outcome"] === "replacement" ? "replacement" : "credit",
    rma: text(r["rma"]),
    currency: text(r["currency"]) ?? "GBP",
    creditLeftMinor: finite(r["credit_left_minor"]) ?? 0,
    awaited: finite(r["awaited"]) ?? 0,
    mayReceive: r["may_receive"] === true,
    receipts,
  };
}

/** Whether a return's page offers Receive the replacement: the database says yes, and something is awaited. */
export function canReceiveReplacement(r: SupplierReturn | null): r is SupplierReturn {
  return r !== null && r.outcome === "replacement" && r.mayReceive && r.awaited > 0;
}

/** One row of erp_supplier_credit_notes, or null when it is not one. */
export function supplierCredit(row: unknown): SupplierCredit | null {
  const r = asRecord(row);
  if (!r) return null;
  const creditNoteId = text(r["credit_note_id"]);
  const left = finite(r["left_minor"]);
  if (creditNoteId === null || left === null) return null;
  const bills = Array.isArray(r["bills"])
    ? r["bills"].map(asRecord).flatMap((b) => {
        const documentId = text(b?.["document_id"]);
        const owes = finite(b?.["owes_minor"]);
        return documentId !== null && owes !== null && owes > 0
          ? [{ documentId, number: text(b?.["document_number"]) ?? "a bill", owesMinor: owes }]
          : [];
      })
    : [];
  return {
    creditNoteId,
    creditNoteNumber: text(r["credit_note_number"]) ?? "a credit note",
    supplier: text(r["party_name"]) ?? "the supplier",
    currency: text(r["currency"]) ?? "GBP",
    leftMinor: left,
    allocatable: r["allocatable"] === true,
    bills,
  };
}

/** Whether a credit's row offers Allocate: the database says yes, and there is a bill to take it. */
export function canAllocateCredit(c: SupplierCredit | null): c is SupplierCredit {
  return c !== null && c.allocatable && c.leftMinor > 0 && c.bills.length > 0;
}

/**
 * What an allocation did, from erp_allocate_supplier_credit's answer: "£50.00
 * of PCN-000003 allocated to PINV-000005, which is paid." The bill is linked.
 */
export function supplierCreditOutcome(result: unknown): Outcome | null {
  const r = asRecord(result);
  if (!r) return null;
  const allocated = finite(r["allocated_minor"]);
  const owes = finite(r["bill_owes_minor"]);
  const billId = text(r["bill_id"]);
  if (allocated === null || owes === null || billId === null) return null;
  const currency = text(r["currency"]) ?? "GBP";
  const bill = text(r["bill_number"]) ?? "the bill";
  const credit = text(r["credit_note_number"]) ?? "the credit note";
  const left = finite(r["credit_left_minor"]) ?? 0;
  const money = (n: number) => formatMinor(n, currency);
  const owing = owes === 0 ? `${bill}, which is paid` : `${bill}, which owes ${money(owes)}`;
  const rest = left > 0 ? ` ${money(left)} of ${credit} is still to use.` : "";
  return {
    message: `${money(allocated)} of ${credit} allocated to ${owing}.${rest}`,
    documents: [{ documentId: billId, number: bill }],
  };
}
