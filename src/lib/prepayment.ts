import { formatMinor } from "./money";
import type { Outcome } from "./plain-words";

/**
 * Supplier prepayments (20261004900000): money a supplier asked for before
 * the goods, asked for on the purchase order, paid by the payment run and
 * taken by the supplier's bill.
 *
 * An order's prepayment is what public.erp_order_prepayment answers; a row of
 * Supplier prepayments is what public.erp_supplier_prepayments answers; and an
 * allocation by hand is what public.erp_allocate_prepayment answers.
 *
 * The screens draw Request on an order only where the database says the reader
 * may ask (procurement.order on an order that may be prepaid), and Allocate on
 * a prepayment only where it says the reader may allocate (finance.post in its
 * company) and names an open bill of the same supplier to take it. The doors
 * refuse regardless; this only keeps a button off a place it would refuse.
 */

export type PrepaymentPayment = { documentId: string; number: string; paidMinor: number };

export type OrderPrepayment = {
  orderId: string;
  currency: string;
  orderGrossMinor: number;
  requestedMinor: number;
  paidMinor: number;
  usedMinor: number;
  leftMinor: number;
  dueMinor: number;
  dueOn: string | null;
  reason: string | null;
  mayRequest: boolean;
  payments: PrepaymentPayment[];
};

export type PrepaymentBill = { documentId: string; number: string; owesMinor: number };

export type SupplierPrepayment = {
  orderId: string;
  orderNumber: string;
  supplier: string;
  currency: string;
  leftMinor: number;
  cancelled: boolean;
  allocatable: boolean;
  bills: PrepaymentBill[];
};

type Row = Record<string, unknown>;

const asRecord = (v: unknown): Row | null =>
  typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Row) : null;

const finite = (v: unknown): number | null => {
  const n = Number(v);
  return v === null || v === undefined || v === "" || !Number.isFinite(n) ? null : n;
};

const text = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);

/** What erp_order_prepayment answered, or null when it is not an order's prepayment. */
export function orderPrepayment(result: unknown): OrderPrepayment | null {
  const r = asRecord(result);
  if (!r) return null;
  const orderId = text(r["order_id"]);
  const requested = finite(r["requested_minor"]);
  if (orderId === null || requested === null) return null;
  const payments = Array.isArray(r["payments"])
    ? r["payments"].map(asRecord).flatMap((p) => {
        const documentId = text(p?.["document_id"]);
        const paid = finite(p?.["paid_minor"]);
        return documentId !== null && paid !== null
          ? [{ documentId, number: text(p?.["document_number"]) ?? "a payment", paidMinor: paid }]
          : [];
      })
    : [];
  return {
    orderId,
    currency: text(r["currency"]) ?? "GBP",
    orderGrossMinor: finite(r["order_gross_minor"]) ?? 0,
    requestedMinor: requested,
    paidMinor: finite(r["paid_minor"]) ?? 0,
    usedMinor: finite(r["used_minor"]) ?? 0,
    leftMinor: finite(r["left_minor"]) ?? 0,
    dueMinor: finite(r["due_minor"]) ?? 0,
    dueOn: text(r["due_on"]),
    reason: text(r["reason"]),
    mayRequest: r["may_request"] === true,
    payments,
  };
}

/**
 * Whether an order's page shows its prepayment at all: something was asked
 * for or paid, or the reader may ask. An order nobody prepaid and the reader
 * may not prepay says nothing about it.
 */
export function showsPrepayment(p: OrderPrepayment | null): p is OrderPrepayment {
  return p !== null && (p.requestedMinor > 0 || p.paidMinor > 0 || p.mayRequest);
}

/** One row of erp_supplier_prepayments, or null when it is not one. */
export function supplierPrepayment(row: unknown): SupplierPrepayment | null {
  const r = asRecord(row);
  if (!r) return null;
  const orderId = text(r["order_id"]);
  const left = finite(r["left_minor"]);
  if (orderId === null || left === null) return null;
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
    orderId,
    orderNumber: text(r["order_number"]) ?? "an order",
    supplier: text(r["party_name"]) ?? "the supplier",
    currency: text(r["currency"]) ?? "GBP",
    leftMinor: left,
    cancelled: r["order_cancelled"] === true,
    allocatable: r["allocatable"] === true,
    bills,
  };
}

/** Whether a prepayment's row offers Allocate: the database says yes, and there is a bill to take it. */
export function canAllocatePrepayment(p: SupplierPrepayment | null): p is SupplierPrepayment {
  return p !== null && p.allocatable && p.leftMinor > 0 && p.bills.length > 0;
}

/**
 * What an allocation did, from erp_allocate_prepayment's answer: "£50.00 of
 * the prepayment on PO-000006 allocated to PINV-000005, which is paid." The
 * bill is linked.
 */
export function prepaymentAllocationOutcome(result: unknown): Outcome | null {
  const r = asRecord(result);
  if (!r) return null;
  const allocated = finite(r["allocated_minor"]);
  const owes = finite(r["bill_owes_minor"]);
  const billId = text(r["bill_id"]);
  if (allocated === null || owes === null || billId === null) return null;
  const currency = text(r["currency"]) ?? "GBP";
  const bill = text(r["bill_number"]) ?? "the bill";
  const order = text(r["order_number"]) ?? "the order";
  const left = finite(r["prepayment_left_minor"]) ?? 0;
  const money = (n: number) => formatMinor(n, currency);
  const owing = owes === 0 ? `${bill}, which is paid` : `${bill}, which owes ${money(owes)}`;
  const rest = left > 0 ? ` ${money(left)} is still prepaid on ${order}.` : "";
  return {
    message: `${money(allocated)} of the prepayment on ${order} allocated to ${owing}.${rest}`,
    documents: [{ documentId: billId, number: bill }],
  };
}
