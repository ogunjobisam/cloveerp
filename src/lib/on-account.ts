import { formatMinor } from "./money";
import type { Outcome } from "./plain-words";

/**
 * Credit on account (20260930400000): cash a customer paid beyond what they
 * owed, kept on their account, as public.erp_on_account_credits answers it, and
 * what allocating it to an invoice did, as public.erp_allocate_on_account
 * answers.
 *
 * The screen draws Allocate on a credit's row only where the database says
 * the reader may allocate it (finance.post in its company) and there is an
 * open invoice of the same customer, company and currency to take it. The
 * door refuses regardless; this only keeps a button off a row it would refuse.
 */

export type OnAccountInvoice = { documentId: string; number: string; owesMinor: number };

export type OnAccountCredit = {
  creditItemId: string;
  customer: string;
  currency: string;
  leftMinor: number;
  allocatable: boolean;
  invoices: OnAccountInvoice[];
};

type Row = Record<string, unknown>;

const asRecord = (v: unknown): Row | null =>
  typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Row) : null;

const finite = (v: unknown): number | null => {
  const n = Number(v);
  return v === null || v === undefined || v === "" || !Number.isFinite(n) ? null : n;
};

/** One row of erp_on_account_credits, or null when it is not one. */
export function onAccountCredit(row: unknown): OnAccountCredit | null {
  const r = asRecord(row);
  if (!r) return null;
  const id = r["credit_item_id"];
  const left = finite(r["left_minor"]);
  if (typeof id !== "string" || id === "" || left === null) return null;
  const invoices = Array.isArray(r["invoices"])
    ? r["invoices"].map(asRecord).flatMap((i) => {
        const documentId = i?.["document_id"];
        const owes = finite(i?.["owes_minor"]);
        const number = i?.["document_number"];
        return typeof documentId === "string" && owes !== null && owes > 0
          ? [
              {
                documentId,
                number: typeof number === "string" ? number : "an invoice",
                owesMinor: owes,
              },
            ]
          : [];
      })
    : [];
  return {
    creditItemId: id,
    customer: typeof r["party_name"] === "string" ? r["party_name"] : "the customer",
    currency: typeof r["currency"] === "string" ? r["currency"] : "GBP",
    leftMinor: left,
    allocatable: r["allocatable"] === true,
    invoices,
  };
}

/** Whether a credit's row offers Allocate: the database says yes, and there is somewhere to put it. */
export function canAllocate(credit: OnAccountCredit | null): credit is OnAccountCredit {
  return (
    credit !== null && credit.allocatable && credit.leftMinor > 0 && credit.invoices.length > 0
  );
}

/**
 * What an allocation did, from erp_allocate_on_account's answer: "£100.00 of
 * the credit on account allocated to INV-000002, which owes £200.00." The
 * invoice is linked.
 */
export function allocationOutcome(result: unknown): Outcome | null {
  const r = asRecord(result);
  if (!r) return null;
  const allocated = finite(r["allocated_minor"]);
  const owes = finite(r["invoice_owes_minor"]);
  const invoiceId = r["invoice_id"];
  if (allocated === null || owes === null || typeof invoiceId !== "string") return null;
  const currency = typeof r["currency"] === "string" ? r["currency"] : "GBP";
  const number = typeof r["invoice_number"] === "string" ? r["invoice_number"] : "the invoice";
  const left = finite(r["credit_left_minor"]) ?? 0;
  const money = (n: number) => formatMinor(n, currency);
  const invoice = owes === 0 ? `${number}, which is paid` : `${number}, which owes ${money(owes)}`;
  const rest = left > 0 ? ` ${money(left)} is still on account.` : "";
  return {
    message: `${money(allocated)} of the credit on account allocated to ${invoice}.${rest}`,
    documents: [{ documentId: invoiceId, number }],
  };
}
