/**
 * A purchase order's sends to its supplier (20261004920000), as
 * public.erp_purchase_order_sends answers them: the address the next send
 * goes to, whether the reader may send, whether a send must say why, and each
 * send so far with how far it got.
 *
 * The order's page draws Send to supplier only where the database says the
 * reader may send it, and asks why only where a send has gone already. The door
 * refuses regardless.
 */

export type SendStatus =
  "queued" | "sending" | "sent" | "delivered" | "opened" | "bounced" | "failed";

export type PurchaseOrderSend = {
  id: string;
  issuedNumber: string;
  to: string;
  cc: string[];
  status: SendStatus;
  when: string | null;
  sentBy: string | null;
  reason: string | null;
  problem: string | null;
  copyKept: boolean;
};

export type PurchaseOrderSends = {
  defaultTo: string | null;
  maySend: boolean;
  needsReason: boolean;
  sends: PurchaseOrderSend[];
};

/**
 * What a send changes, and so is read again after it: the sends, the order,
 * and what a sent order starts — the supplier's confirmation, the orders
 * awaiting one, and its shipping notices. The confirmation read before the
 * send answers nothing, and without these it went on answering nothing until
 * the page was loaded again (J-53).
 */
export const SEND_READS_AGAIN: readonly string[] = [
  "erp_purchase_order_sends",
  "erp_document",
  "erp_documents",
  "erp_available_transitions",
  "erp_purchase_order_confirmation",
  "erp_awaiting_confirmations",
  "erp_order_shipping_notices",
];

type Row = Record<string, unknown>;

const asRecord = (v: unknown): Row | null =>
  typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Row) : null;

const text = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);

/**
 * Where a send got to, in one word: what the provider reported once it has,
 * otherwise the queue's own state. A bounce outranks a sent; a failure is a
 * failure whatever came before.
 */
export function sendStatus(status: unknown, delivery: unknown): SendStatus {
  if (status === "failed") return "failed";
  if (delivery === "bounced" || delivery === "complained") return "bounced";
  if (delivery === "opened") return "opened";
  if (delivery === "delivered") return "delivered";
  if (status === "sent") return "sent";
  if (status === "sending") return "sending";
  return "queued";
}

/** What erp_purchase_order_sends answered, or null when it is not an order's sends. */
export function purchaseOrderSends(result: unknown): PurchaseOrderSends | null {
  const r = asRecord(result);
  if (!r || text(r["order_id"]) === null) return null;
  const sends = Array.isArray(r["sends"])
    ? r["sends"].map(asRecord).flatMap((s) => {
        const id = text(s?.["document_email_id"]);
        const to = text(s?.["to_address"]);
        if (!s || id === null || to === null) return [];
        const status = sendStatus(s["status"], s["delivery_state"]);
        return [
          {
            id,
            issuedNumber: text(s["issued_number"]) ?? "",
            to,
            cc: Array.isArray(s["cc"])
              ? s["cc"].filter((c): c is string => typeof c === "string")
              : [],
            status,
            when: text(s["delivery_state_at"]) ?? text(s["sent_at"]) ?? text(s["queued_at"]),
            sentBy: text(s["sent_by"]),
            reason: text(s["reason"]),
            problem:
              status === "failed" || status === "bounced"
                ? (text(s["delivery_detail"]) ?? text(s["failure_reason"]))
                : text(s["document_problem"]),
            copyKept: s["document_kept"] === true,
          },
        ];
      })
    : [];
  return {
    defaultTo: text(r["default_to"]),
    maySend: r["may_send"] === true,
    needsReason: r["needs_reason"] === true,
    sends,
  };
}
