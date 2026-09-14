/**
 * What the console says about an order form or invoice on its way to the
 * customer.
 *
 * Issuing either one queues it for every recipient (20260914097000), and
 * public.erp_platform_commercial_emails() reads back who it goes to and every
 * send so far. This file turns that into the words beside the document: "Sent
 * to Dana Buyer <dana@okafor.example> at 14 Sep 2026, 10:15", "No customer
 * email on this quote", and which send is the latest.
 *
 * Pure, so the wording is tested without a browser.
 */

export type CommercialRecipient = { address: string; name: string | null; source: string };

export type CommercialSend = {
  id: string;
  kind: string;
  document_id: string;
  send_number: number;
  to_address: string;
  to_name: string | null;
  recipient_source: string;
  status: string;
  attempts: number;
  sent_at: string | null;
  failure_reason: string | null;
  requested_by: string;
  created_at: string;
};

export type CommercialEmailState = {
  demonstration: boolean;
  recipients: CommercialRecipient[];
  sends: CommercialSend[];
  billing_email?: string | null;
  billing_name?: string | null;
};

export type SendTone = "ok" | "warn" | "bad" | "muted";

/** "Dana Buyer <dana@okafor.example>", or the address alone. */
export function recipientLabel(address: string, name: string | null | undefined): string {
  const n = (name ?? "").trim();
  return n ? `${n} <${address}>` : address;
}

/** Why a recipient receives it, as the end of a sentence. */
export function sourceWords(source: string): string {
  switch (source) {
    case "customer_contact":
      return "the customer contact on this quote";
    case "customer_administrator":
      return "an administrator of the organisation the quote was made for";
    case "billing_contact":
      return "the contract's billing contact";
    case "administrator":
      return "an administrator of the customer's organisation";
    default:
      return "a recipient";
  }
}

/** "14 Sep 2026, 10:15" in the reader's own zone; the text given when it is not a time. */
export function whenText(iso: string | null | undefined): string {
  if (!iso) return "—";
  const when = new Date(iso);
  if (Number.isNaN(when.getTime())) return iso;
  const day = when.toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" });
  const time = when.toLocaleTimeString("en-GB", {
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  });
  return `${day}, ${time}`;
}

/** One send, in a line: what happened to it, to whom, and when or why. */
export function describeSend(send: CommercialSend): { tone: SendTone; text: string } {
  const to = recipientLabel(send.to_address, send.to_name);
  const reason = (send.failure_reason ?? "").trim();
  switch (send.status) {
    case "sent":
      return { tone: "ok", text: `Sent to ${to} at ${whenText(send.sent_at)}` };
    case "sending":
      return { tone: "muted", text: `Being sent to ${to}` };
    case "queued":
      return reason
        ? { tone: "warn", text: `Trying again for ${to}: ${reason}` }
        : { tone: "muted", text: `Waiting to go to ${to}` };
    case "failed":
      return { tone: "bad", text: `Not sent to ${to}: ${reason || "the send failed"}` };
    case "cancelled":
      return { tone: "muted", text: `Not sent to ${to}: ${reason || "cancelled"}` };
    default:
      return { tone: "muted", text: `${send.status} for ${to}` };
  }
}

/** The latest send of one document: every recipient of its highest send number. */
export function latestSends(
  sends: readonly CommercialSend[],
  documentId: string,
): CommercialSend[] {
  const mine = sends.filter((s) => s.document_id === documentId);
  if (mine.length === 0) return [];
  const last = Math.max(...mine.map((s) => s.send_number));
  return mine
    .filter((s) => s.send_number === last)
    .sort((a, b) => a.to_address.localeCompare(b.to_address));
}

/** Who a document goes to, as a sentence; or why nobody. */
export function recipientsSentence(
  kind: "order_form" | "contract_invoice",
  recipients: readonly CommercialRecipient[],
  demonstration: boolean,
): string {
  if (demonstration) return "A demonstration organisation is never emailed.";
  if (recipients.length === 0) {
    return kind === "order_form"
      ? "No customer email on this quote"
      : "Nobody to send invoices to: the contract has no billing contact and the organisation has no administrator with an email address.";
  }
  const first = recipients[0]!;
  if (recipients.length === 1) {
    return `Goes to ${recipientLabel(first.address, first.name)}, ${sourceWords(first.source)}.`;
  }
  const names = recipients.map((r) => recipientLabel(r.address, r.name));
  const list = `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`;
  return first.source === "customer_administrator"
    ? `Goes to ${list}, the administrators of the organisation the quote was made for.`
    : `Goes to ${list}, the administrators of the customer's organisation.`;
}
