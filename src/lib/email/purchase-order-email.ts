/**
 * The email a supplier receives with a purchase order (20261004920000).
 *
 * The dispatch drain claims each send a buyer makes (erp.document_email) with
 * the order as its issue froze it, and this turns that into the subject and the
 * message, in the one layout every email is written in (layout.ts). The order
 * itself travels as the attached PDF (src/lib/pdf/purchase-order-pdf.ts); the
 * email says what it is, the figures a supplier checks first, the buyer's
 * message, and who to reply to.
 *
 * The subject carries only product words and the order's number: what an
 * organisation typed goes in the body, where it is escaped. Imports only the
 * layout and the money formatter, by relative paths with their extensions, so
 * the dispatch Edge Function can follow them.
 */
import { renderEmail, oneLine, type EmailDetail, type EmailInput } from "./layout.ts";
import { formatMinor } from "../money.ts";

export type ClaimedDocumentEmail = {
  id: string;
  document_kind: string;
  to_address: string;
  to_name: string | null;
  cc_addresses: string[] | null;
  from_address: string;
  from_name: string | null;
  reply_to: string | null;
  message: string | null;
  idempotency_key: string;
  attempt: number;
  issued_number: string;
  organisation_name: string | null;
  payload: unknown;
  /**
   * The token of the link the supplier answers through (20261004990000), the
   * only copy there is; null for a send claimed before links existed.
   */
  response_token?: string | null;
};

export type DocumentEmail = { subject: string; text: string; html: string };

/** A payload this file cannot write an email from. The message says what was wrong. */
export class DocumentEmailError extends Error {}

type Dict = Record<string, unknown>;

function dict(value: unknown): Dict | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Dict)
    : null;
}

function text(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
}

function day(value: unknown): string | null {
  const v = text(value);
  const m = v ? /^(\d{4})-(\d{2})-(\d{2})/.exec(v) : null;
  if (!m) return null;
  return new Intl.DateTimeFormat("en-GB", {
    day: "numeric",
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  }).format(new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]))));
}

function usable(address: unknown): string | null {
  const v = text(address);
  return v && /^[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+$/.test(v) ? v : null;
}

/**
 * The sender as the provider takes it: the organisation's name in quotes
 * before the address, or the bare address when there is no usable name. Quotes
 * and angle brackets in a name are dropped rather than escaped, because the
 * provider takes neither inside a display name.
 */
export function namedSender(name: string | null, address: string): string {
  const clean = (name ?? "")
    .replace(/["<>\\]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 70);
  return clean ? `"${clean}" <${address}>` : address;
}

/**
 * The email for one claimed purchase order send. Throws DocumentEmailError for
 * a payload it cannot read; the drain fails that row and says why.
 *
 * attachment is the file name of the PDF going with it, when one is: the email
 * then says the order is attached. Without it the email says so plainly and
 * gives the order's figures, so a supplier is never pointed at a file that is
 * not there.
 */
/**
 * Where the supplier answers the order: /respond, with the token in the
 * fragment so no server, log or link scanner receives it (20261004990000).
 * Null without an origin or a well-formed token.
 */
export function respondUrl(
  origin: string | null | undefined,
  token: string | null | undefined,
): string | null {
  const base = origin?.trim().replace(/\/+$/, "") ?? "";
  if (base === "" || !token || !/^[0-9a-f]{64}$/.test(token)) return null;
  return `${base}/respond#t=${token}`;
}

export function composePurchaseOrderEmail(
  row: ClaimedDocumentEmail,
  options: { attachment?: string | null; appOrigin?: string | null } = {},
): DocumentEmail {
  if (row.document_kind !== "purchase_order") {
    throw new DocumentEmailError(`${row.document_kind} is not a purchase order`);
  }
  const payload = dict(row.payload);
  const header = dict(payload?.["header"]);
  const company = dict(payload?.["company"]);
  const totals = dict(payload?.["totals"]);
  const delivery = dict(payload?.["delivery"]);
  const number = text(header?.["number"]) ?? text(row.issued_number);
  const currency = text(header?.["currency"]);
  if (!payload || !number || !currency || !totals) {
    throw new DocumentEmailError("the payload has no order number, currency or totals");
  }
  const buyerCompany =
    text(company?.["legal_name"]) ??
    text(row.from_name) ??
    text(row.organisation_name) ??
    "Your customer";
  const buyer = dict(payload["buyer"]);
  const buyerName = text(buyer?.["name"]);
  const replyTo = usable(row.reply_to) ?? usable(buyer?.["email"]);
  const attachment = options.attachment?.trim() || null;
  const reason = text(payload["reason"]);
  const lines = Array.isArray(payload["lines"]) ? payload["lines"].length : 0;
  const total = formatMinor(Number(totals["gross_minor"] ?? totals["net_minor"] ?? 0), currency, 2);
  const required = day(header?.["required_date"]);
  const respond = respondUrl(options.appOrigin, row.response_token);

  const subject = reason
    ? `Purchase order ${oneLine(number, 40)}, sent again`
    : `Purchase order ${oneLine(number, 40)}`;
  const details: EmailDetail[] = [
    { label: "Order", value: number },
    { label: "Date", value: day(header?.["order_date"]) ?? "" },
    { label: "Lines", value: String(lines) },
    { label: "Total", value: total },
    { label: "Required by", value: required ?? "" },
    { label: "Your reference", value: text(header?.["their_reference"]) ?? "" },
    {
      label: "Deliver to",
      value: [text(delivery?.["site"])].filter(Boolean).join(", "),
    },
    { label: "Buyer", value: [buyerName, replyTo].filter(Boolean).join(", ") },
  ];

  const input: EmailInput = {
    title: subject,
    lang: "en-GB",
    organisation: buyerCompany,
    preheader: `${buyerCompany} has placed order ${number} with you, ${total}.`,
    greeting: text(row.to_name) ? `Hello ${oneLine(row.to_name ?? "", 60)},` : "Hello,",
    heading: subject,
    intro: [
      reason
        ? `${buyerCompany} is sending order ${number} again. This copy replaces the one sent earlier: ${reason}`
        : `${buyerCompany} has placed order ${number} with you.`,
      attachment
        ? `The order is attached as a PDF, ${attachment}, with every line, price and the delivery address.`
        : "The order's figures are below. Reply if you need it as a PDF.",
      respond
        ? "Please confirm it, or tell us what you can send and when, with the button below. No account is needed."
        : null,
      `Please quote ${number} on your delivery note and your invoice.`,
    ].filter((line): line is string => line !== null),
    details,
    quote: text(row.message),
    primary: respond
      ? { label: "Confirm this order", url: respond }
      : replyTo
        ? {
            label: "Reply about this order",
            url: `mailto:${replyTo}?subject=${encodeURIComponent(`Order ${number}`)}`,
          }
        : { label: "Visit cloveerp.com", url: "https://cloveerp.com" },
    secondary:
      respond && replyTo
        ? {
            label: "Reply about this order",
            url: `mailto:${replyTo}?subject=${encodeURIComponent(`Order ${number}`)}`,
          }
        : null,
    reason: `You are receiving this because ${buyerCompany} sent you a purchase order from Clove ERP, the system they buy through.`,
    mandatory: "This email is the order itself, so it is sent whatever your email preferences say.",
    footer: `Sent for ${buyerCompany} by Clove ERP.`,
  };
  const rendered = renderEmail(input);
  return { subject, text: rendered.text, html: rendered.html };
}
