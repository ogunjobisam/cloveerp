/**
 * An issued order form or contract invoice, as the email the customer receives.
 *
 * Issuing either one queues a row per recipient in erp_meta.commercial_email
 * (20260914097300). The dispatch drain claims them with
 * erp.claim_commercial_email_batch(), which returns everything an email needs
 * as a payload: for an order form its number, customer, lines with discount
 * and net, totals, term and validity; for an invoice its reference, lines,
 * total, due date, VAT statement and where to pay. This file turns a payload
 * into renderEmail() input and the subject line.
 *
 * The database decides what is true: who it goes to, the figures, the VAT
 * wording (erp.contract_invoice_terms) and the payment details. This file
 * decides how it reads: money and dates for a reader in the United Kingdom,
 * rows in a fixed order, the buttons. A payload it cannot read throws
 * CommercialEmailError, and the drain fails the row rather than sending half a
 * document: unlike a notification, an invoice has no plain body to fall back
 * on that would still be right.
 *
 * Imports only the layout, by a relative path with its extension, so the
 * dispatch worker, the dispatch Edge Function under Deno and the desk can all
 * read it.
 */

import { oneLine, renderEmail, type EmailDetail, type EmailInput } from "./layout.ts";

/** What erp.claim_commercial_email_batch() returns, as far as an email needs it. */
export type ClaimedCommercialEmail = {
  email_id: string;
  email_kind: string;
  recipient_address: string | null;
  recipient_name: string | null;
  sender_address: string | null;
  reply_address: string | null;
  send_key: string;
  attempt?: number | null;
  payload: unknown;
};

export type CommercialEmail = { subject: string; text: string; html: string };

/** A payload this file cannot make an email of. The message says what was wrong. */
export class CommercialEmailError extends Error {}

/** Where the customer reads its own invoices once signed in. */
export const INVOICE_PATH = "/administration/commercial";

type Dict = Record<string, unknown>;

function dict(value: unknown, what: string): Dict {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new CommercialEmailError(`${what} is not an object`);
  }
  return value as Dict;
}

function text(value: unknown): string | null {
  if (typeof value === "string") return value.trim() === "" ? null : value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return null;
}

function need(d: Dict, key: string, what: string): string {
  const value = text(d[key]);
  if (value === null) throw new CommercialEmailError(`${what} has no ${key}`);
  return value;
}

function num(value: unknown): number | null {
  const n = typeof value === "string" && value.trim() !== "" ? Number(value) : value;
  return typeof n === "number" && Number.isFinite(n) ? n : null;
}

/** Minor units as money for a reader in the UK: 1182600 GBP is "£11,826.00". */
export function formatMoney(minor: unknown, currency: unknown): string | null {
  const amount = num(minor);
  if (amount === null) return null;
  if (typeof currency !== "string" || !/^[A-Z]{3}$/.test(currency)) return null;
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency,
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(amount / 100);
}

/** A calendar date as a person says it: "28 September 2026". Never shifted by a zone. */
export function formatDay(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(value.trim());
  if (!m) return null;
  const when = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  if (Number.isNaN(when.getTime())) return null;
  return new Intl.DateTimeFormat("en-GB", {
    day: "numeric",
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  }).format(when);
}

/** How long the order form's term is, in words. */
export function describeTerm(kind: unknown, months: unknown): string | null {
  const m = num(months);
  switch (kind) {
    case "annual":
      return "12 months, billed yearly";
    case "monthly":
      return "Month to month, billed monthly";
    case "multi_year": {
      const years = m !== null && m >= 24 ? Math.round(m / 12) : null;
      return years ? `${years} years, billed yearly` : "Several years, billed yearly";
    }
    default:
      return null;
  }
}

function quantity(value: unknown): string {
  const n = num(value);
  if (n === null) return "1";
  return Number.isInteger(n) ? n.toLocaleString("en-GB") : String(Number(n.toFixed(4)));
}

/** "2 × £45.00, 10% off: £81.00", or "£13,140.00" for one at list price. */
export function describeLine(line: Dict, currency: string): string {
  const net = formatMoney(line["net_minor"], currency);
  if (net === null) throw new CommercialEmailError("a line has no net");
  const unit = formatMoney(line["unit_price_minor"], currency);
  const count = quantity(line["quantity"]);
  const discount = num(line["discount_pct"]) ?? 0;
  const parts: string[] = [];
  if (unit !== null && (count !== "1" || discount > 0)) parts.push(`${count} × ${unit}`);
  if (discount > 0) parts.push(`${Number(discount.toFixed(2))}% off`);
  const lead = parts.join(", ");
  const once = line["charge"] === "one_off" ? " (charged once)" : "";
  return `${lead ? `${lead}: ` : ""}${net}${once}`;
}

function linesOf(payload: Dict): Dict[] {
  const lines = payload["lines"];
  if (!Array.isArray(lines)) throw new CommercialEmailError("the payload has no lines");
  return lines.map((l, i) => dict(l, `line ${i + 1}`));
}

function greeting(name: unknown): string {
  const n = oneLine(text(name) ?? "", 80);
  return n ? `Hello ${n},` : "Hello,";
}

function mailto(address: string, subject: string): string {
  return `mailto:${address}?subject=${encodeURIComponent(subject)}`;
}

function usableAddress(value: unknown): string | null {
  const t = text(value);
  return t !== null && /^[^@\s<>"]+@[^@\s<>"]+\.[A-Za-z]{2,}$/.test(t) ? t : null;
}

/* -------------------------------------------------------------------------- */
/* The order form                                                             */
/* -------------------------------------------------------------------------- */

function orderFormInput(
  row: ClaimedCommercialEmail,
  payload: Dict,
  origin: string,
  attachment: string | null,
) {
  const number = need(payload, "document_number", "the order form");
  const customer = need(payload, "customer_name", "the order form");
  const currency = need(payload, "currency", "the order form");
  const totals = dict(payload["totals"], "the order form's totals");
  const lines = linesOf(payload);
  if (lines.length === 0) throw new CommercialEmailError("the order form has no lines");

  const net = formatMoney(totals["net_minor"], currency);
  if (net === null) throw new CommercialEmailError("the order form has no total");
  const recurring = formatMoney(totals["recurring_minor"], currency);
  const oneOff = num(totals["one_off_minor"])
    ? formatMoney(totals["one_off_minor"], currency)
    : null;
  const discount = num(totals["discount_minor"])
    ? formatMoney(totals["discount_minor"], currency)
    : null;
  const validUntil = formatDay(payload["valid_until"]);
  const term = describeTerm(payload["term_kind"], payload["term_months"]);

  const subject = `Your order form from Clove ERP: ${oneLine(number, 40)}`;
  const details: EmailDetail[] = [
    ...lines.map((l) => ({
      label: text(l["description"]) ?? text(l["item_code"]) ?? "Line",
      value: describeLine(l, currency),
    })),
    ...(discount ? [{ label: "Discounts", value: `${discount} off the list price` }] : []),
    ...(recurring && oneOff ? [{ label: "Recurring", value: recurring }] : []),
    ...(oneOff ? [{ label: "Charged once", value: oneOff }] : []),
    { label: "Total", value: net },
    ...(term ? [{ label: "Term", value: term }] : []),
    ...(validUntil ? [{ label: "Valid until", value: validUntil }] : []),
  ];

  const issuer = usableAddress(payload["issuer_email"]) ?? usableAddress(row.reply_address);
  const primary = issuer
    ? { label: "Reply to accept or ask a question", url: mailto(issuer, `Order form ${number}`) }
    : { label: "Visit cloveerp.com", url: origin };

  const input: EmailInput = {
    title: subject,
    lang: "en-GB",
    organisation: customer,
    preheader: `The order form for ${customer}${validUntil ? `, valid until ${validUntil}` : ""}.`,
    greeting: greeting(row.recipient_name ?? payload["recipient_name"]),
    heading: subject,
    intro: [
      `Here is the order form for ${customer}, with the price as quoted.`,
      validUntil
        ? `It is valid until ${validUntil}. To accept it, reply to this email and say so; to change anything, reply and say what.`
        : "To accept it, reply to this email and say so; to change anything, reply and say what.",
      ...(attachment
        ? [
            `The order form is attached as a PDF, ${attachment}, with a place to sign it for your records.`,
          ]
        : []),
    ],
    details,
    primary,
    secondary: null,
    note: "The order form is the whole of the price: nothing is added to it when you accept.",
    reason: `You are receiving this because Clove ERP prepared this order form for ${customer} and you are its contact.`,
    mandatory:
      "This email is the order form itself, so it is sent whatever your email preferences say.",
  };
  return { subject, input };
}

/* -------------------------------------------------------------------------- */
/* The invoice                                                                */
/* -------------------------------------------------------------------------- */

function invoiceLineLabel(line: Dict): string {
  switch (line["kind"]) {
    case "subscription":
      return "Subscription";
    case "one_off":
      return text(line["description"]) ?? "Charged once";
    case "overage": {
      const what = (text(line["entitlement_code"]) ?? "usage").replaceAll("_", " ");
      const month = formatDay(line["month"]);
      return `Over the limit on ${what}${month ? `, ${month.replace(/^\d+ /, "")}` : ""}`;
    }
    default:
      return text(line["description"]) ?? "Line";
  }
}

function invoiceLineValue(line: Dict, currency: string): string {
  const net = formatMoney(line["net_minor"], currency);
  if (net === null) throw new CommercialEmailError("an invoice line has no net");
  if (line["kind"] === "subscription") {
    const what = text(line["description"]);
    return what ? `${net} (${oneLine(what, 120)})` : net;
  }
  if (line["kind"] === "one_off") return `${net} (charged once)`;
  return net;
}

/** The payment details, as the lines a customer copies into a bank payment. */
export function paymentBlock(details: unknown, reference: string): string | null {
  if (typeof details !== "object" || details === null || Array.isArray(details)) return null;
  const d = details as Dict;
  const name = text(d["bank_account_name"]);
  const sort = text(d["sort_code"]);
  const account = text(d["account_number"]);
  if (!name || !sort || !account) return null;
  const guidance = text(d["payment_reference_guidance"]);
  const company = text(d["legal_name"]);
  const number = text(d["company_number"]);
  const address = text(d["registered_address"]);
  return [
    `Account name: ${name}`,
    `Sort code: ${sort}`,
    `Account number: ${account}`,
    `Payment reference: ${reference}`,
    ...(guidance ? [guidance] : []),
    ...(company
      ? [
          "",
          `${company}${number ? `, company number ${number}` : ""}`,
          ...(address ? [address] : []),
        ]
      : []),
  ].join("\n");
}

function invoiceInput(
  row: ClaimedCommercialEmail,
  payload: Dict,
  origin: string,
  attachment: string | null,
) {
  const reference = need(payload, "reference", "the invoice");
  const customer = need(payload, "customer_name", "the invoice");
  const currency = need(payload, "currency", "the invoice");
  const due = formatDay(payload["due_on"]);
  if (due === null) throw new CommercialEmailError("the invoice has no due date");
  const total = formatMoney(payload["total_minor"], currency);
  if (total === null) throw new CommercialEmailError("the invoice has no total");
  const statement = text(payload["tax_statement"]);
  if (statement === null) throw new CommercialEmailError("the invoice has no VAT statement");
  const supplier = text(payload["supplier_name"]) ?? "Clove ERP Ltd";
  const lines = linesOf(payload);
  const start = formatDay(payload["period_start"]);
  const end = formatDay(payload["period_end"]);
  const issued = formatDay(payload["issued_on"]);
  const payment = paymentBlock(payload["payment_details"], reference);

  const subject = `Invoice ${oneLine(reference, 60)} is due on ${due}`;
  const details: EmailDetail[] = [
    ...lines.map((l) => ({ label: invoiceLineLabel(l), value: invoiceLineValue(l, currency) })),
    { label: "Total", value: total },
    { label: "Due", value: due },
    ...(start && end ? [{ label: "Period", value: `${start} to ${end}` }] : []),
    ...(issued ? [{ label: "Issued", value: issued }] : []),
    { label: "VAT", value: statement },
  ];

  const input: EmailInput = {
    title: subject,
    lang: "en-GB",
    organisation: customer,
    preheader: `${total} from ${customer} to ${supplier}, due on ${due}.`,
    greeting: greeting(row.recipient_name ?? payload["recipient_name"]),
    heading: subject,
    intro: [
      `${supplier} has issued invoice ${reference} to ${customer} for ${total}.`,
      payment
        ? `Please pay by ${due} into the account below, quoting ${reference}.`
        : `Please pay by ${due}. Payment details will follow from our accounts team.`,
      ...(attachment ? [`The invoice is attached as a PDF, ${attachment}.`] : []),
    ],
    details,
    quote: payment,
    primary: { label: "View your invoice", url: `${origin}${INVOICE_PATH}` },
    secondary: null,
    note: [
      statement,
      "Your invoices, what each one covers and when the next is due are always in Clove ERP under Your agreement.",
    ],
    reason: `You are receiving this because you are the billing contact or an administrator of ${customer} on Clove ERP.`,
    mandatory:
      "This email is the invoice itself, so it is sent whatever your email preferences say.",
  };
  return { subject, input };
}

/* -------------------------------------------------------------------------- */
/* The reminder                                                               */
/* -------------------------------------------------------------------------- */

/** "7 days", and "a day" for one, as a person counts them. */
export function daysWord(days: number): string {
  return days === 1 ? "a day" : `${days} days`;
}

/**
 * An invoice that is past its due date and not recorded as paid
 * (20260915030000). The same figures as the invoice itself, said once more:
 * what is owed, how late it is, how to pay it, and who to reply to. The
 * payload is the invoice's, with the reminder's number and how overdue it was
 * when the drain claimed it.
 *
 * Polite and factual on purpose. A customer whose payment crossed this email
 * in the post should not be accused of anything, and the person reading it is
 * usually not the person who decides when it is paid.
 */
function invoiceReminderInput(
  row: ClaimedCommercialEmail,
  payload: Dict,
  origin: string,
  attachment: string | null,
) {
  const reference = need(payload, "reference", "the reminder");
  const customer = need(payload, "customer_name", "the reminder");
  const currency = need(payload, "currency", "the reminder");
  const due = formatDay(payload["due_on"]);
  if (due === null) throw new CommercialEmailError("the reminder has no due date");
  const total = formatMoney(payload["total_minor"], currency);
  if (total === null) throw new CommercialEmailError("the reminder has no total");
  const overdue = num(payload["days_overdue"]);
  if (overdue === null || overdue < 1) {
    throw new CommercialEmailError("the reminder does not say how overdue the invoice is");
  }
  const days = Math.floor(overdue);
  const supplier = text(payload["supplier_name"]) ?? "Clove ERP Ltd";
  const issued = formatDay(payload["issued_on"]);
  const start = formatDay(payload["period_start"]);
  const end = formatDay(payload["period_end"]);
  const payment = paymentBlock(payload["payment_details"], reference);
  const replyTo = usableAddress(payload["issuer_email"]) ?? usableAddress(row.reply_address);

  const subject = `Invoice ${oneLine(reference, 60)} is ${daysWord(days)} overdue`;
  const details: EmailDetail[] = [
    { label: "Amount due", value: total },
    { label: "Reference", value: reference },
    { label: "Due", value: `${due} (${daysWord(days)} ago)` },
    ...(start && end ? [{ label: "Period", value: `${start} to ${end}` }] : []),
    ...(issued ? [{ label: "Issued", value: issued }] : []),
  ];

  const input: EmailInput = {
    title: subject,
    lang: "en-GB",
    organisation: customer,
    preheader: `${total} on invoice ${reference}, due on ${due}.`,
    greeting: greeting(row.recipient_name ?? payload["recipient_name"]),
    heading: subject,
    intro: [
      `Invoice ${reference} for ${total} was due on ${due}, and we have not recorded a payment for it.`,
      payment
        ? `Please pay ${total} into the account below, quoting ${reference}.`
        : `Please pay ${total}. Payment details will follow from our accounts team.`,
      "If you have paid it in the last few days, thank you — a payment can take a day or two to reach us, and this email crossed it.",
      ...(attachment ? [`The invoice is attached again as a PDF, ${attachment}.`] : []),
    ],
    details,
    quote: payment,
    primary: { label: "View your invoice", url: `${origin}${INVOICE_PATH}` },
    secondary: replyTo
      ? { label: "Reply about this invoice", url: mailto(replyTo, `Invoice ${reference}`) }
      : null,
    note: [
      `Reply to this email if it has been paid, if you need it sent somewhere else, or if something about it is wrong. ${supplier} would rather hear from you than send another reminder.`,
    ],
    reason: `You are receiving this because you are the billing contact or an administrator of ${customer} on Clove ERP.`,
    mandatory:
      "This email is about an unpaid invoice, so it is sent whatever your email preferences say.",
  };
  return { subject, input };
}

/* -------------------------------------------------------------------------- */
/* The one entry point                                                        */
/* -------------------------------------------------------------------------- */

/**
 * The email for one claimed row. Throws CommercialEmailError for a payload it
 * cannot read; the drain fails that row and says why.
 *
 * attachment is the file name of the PDF going with the message, when one is
 * (20260915020000): the email then says it is attached. Without it the email
 * says nothing about a PDF, so a message whose document could not be made
 * never points at an attachment it does not carry.
 */
export function composeCommercialEmail(
  row: ClaimedCommercialEmail,
  origin: string,
  options: { attachment?: string | null } = {},
): CommercialEmail {
  const attachment = options.attachment?.trim() || null;
  const payload = dict(row.payload, "the payload");
  const kind = payload["kind"] ?? row.email_kind;
  const base = origin.replace(/\/+$/, "");
  const shaped =
    kind === "order_form"
      ? orderFormInput(row, payload, base, attachment)
      : kind === "contract_invoice"
        ? invoiceInput(row, payload, base, attachment)
        : kind === "invoice_reminder"
          ? invoiceReminderInput(row, payload, base, attachment)
          : null;
  if (shaped === null)
    throw new CommercialEmailError(
      `${String(kind)} is not an order form, an invoice or a reminder`,
    );
  const rendered = renderEmail(shaped.input);
  return { subject: shaped.subject, text: rendered.text, html: rendered.html };
}
