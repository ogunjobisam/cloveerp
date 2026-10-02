/**
 * A purchase order as its supplier receives it, as a PDF document.
 *
 * The dispatch drain emails each purchase order a buyer sends
 * (20261004920000) with this attached, and keeps a copy in the private
 * document-output bucket against the order's issue; the order's own page draws
 * the same document for sending by hand. Its only input is the payload
 * erp.purchase_order_document() answers, frozen on the issue: the order's
 * number, dates and references, the buying company, the delivery site, the
 * supplier, the lines, the tax and the totals, and the buyer's message. It
 * reads nothing else, so what the supplier is sent is exactly what was frozen,
 * and a cost or an internal note cannot reach it: the payload carries neither.
 *
 * Drawn with the kit commercial-document.ts draws order forms with, so every
 * document the product sends reads as one family. Imports only that file, the
 * money formatter through it and pdf-lib, by relative paths with their
 * extensions, so the dispatch Edge Function can follow them.
 */
import { PDFDocument } from "pdf-lib";
import fontkit from "@pdf-lib/fontkit";
import { NOTO_SANS_BOLD_BASE64, NOTO_SANS_REGULAR_BASE64, fontBytes } from "./fonts.ts";
import {
  ACCENT,
  BRAND,
  FOOTER_Y,
  INK,
  MARGIN,
  MUTED,
  RIGHT,
  RULE,
  Sheet,
  WIDTH,
  dict,
  heading,
  longDate,
  money,
  num,
  printable,
  quantityWords,
  str,
  table,
  titleBlock,
  totals,
  wrapText,
  type Dict,
} from "./commercial-document.ts";

/** A payload this file cannot make a purchase order of. The message says what was wrong. */
export class PurchaseOrderDocumentError extends Error {}

function need(d: Dict | null, key: string, what: string): string {
  const value = d ? str(d[key]) : null;
  if (value === null) throw new PurchaseOrderDocumentError(`${what} has no ${key}`);
  return value;
}

/**
 * An address as the product keeps it, as lines: the usual keys in the usual
 * order, then anything else it holds that is text. A site or a supplier with no
 * address gives none, and nothing is invented.
 */
export function addressLines(value: unknown): string[] {
  const a = dict(value);
  if (!a) return typeof value === "string" && value.trim() ? value.split(/\r?\n|,\s*/) : [];
  const order = [
    "line1",
    "line_1",
    "address_line_1",
    "street",
    "line2",
    "line_2",
    "address_line_2",
    "line3",
    "city",
    "town",
    "locality",
    "region",
    "county",
    "state",
    "postcode",
    "postal_code",
    "zip",
    "country",
    "country_code",
  ];
  const seen = new Set<string>();
  const lines: string[] = [];
  for (const key of [...order, ...Object.keys(a)]) {
    if (seen.has(key)) continue;
    seen.add(key);
    const v = str(a[key]);
    if (v) lines.push(v);
  }
  return lines;
}

/** The name the PDF is attached and downloaded under. */
export function purchaseOrderFilename(payload: unknown): string {
  const header = dict(dict(payload)?.["header"]);
  const number = (str(header?.["number"]) ?? "order").replace(/[^A-Za-z0-9-]+/g, "-");
  return `Purchase-order-${number}.pdf`;
}

/** Where the drain keeps the copy of one send's PDF in the document-output bucket. */
export function purchaseOrderPath(emailId: string): string {
  if (!/^[0-9a-f-]{36}$/.test(emailId)) {
    throw new PurchaseOrderDocumentError(`${emailId} is not an email id`);
  }
  return `purchase-order/${emailId}.pdf`;
}

function linesOf(payload: Dict): Dict[] {
  const lines = payload["lines"];
  if (!Array.isArray(lines)) throw new PurchaseOrderDocumentError("the order has no lines");
  return lines.map((l, i) => {
    const d = dict(l);
    if (!d) throw new PurchaseOrderDocumentError(`line ${i + 1} is not an object`);
    return d;
  });
}

/** The buying company, top right: its legal name, its registration, where the goods go. */
function letterhead(sheet: Sheet, company: Dict, delivery: Dict | null): void {
  const top = sheet.y;
  const name = need(company, "legal_name", "the company");
  for (const [i, piece] of wrapText(sheet.bold, name, 18, WIDTH - 240).entries()) {
    sheet.text(piece, MARGIN, top - 20 - i * 22, { size: 18, font: sheet.bold, color: BRAND });
  }
  const lines: Array<{ value: string; bold: boolean }> = [];
  const registration = str(company["registration_number"]);
  if (registration) lines.push({ value: `Company number ${registration}`, bold: false });
  const site = str(delivery?.["site"]);
  if (site) lines.push({ value: site, bold: true });
  for (const l of addressLines(delivery?.["address"])) lines.push({ value: l, bold: false });

  let y = top - 8;
  for (const l of lines) {
    for (const piece of wrapText(l.bold ? sheet.bold : sheet.regular, l.value, 8.5, 220)) {
      sheet.text(piece, RIGHT - 220, y, {
        size: 8.5,
        font: l.bold ? sheet.bold : sheet.regular,
        color: l.bold ? INK : MUTED,
        width: 220,
        align: "right",
      });
      y -= 11.5;
    }
  }
  sheet.y = Math.min(top - 40, y - 4);
  sheet.rule(sheet.y, MARGIN, RIGHT, ACCENT, 1.2);
  sheet.y -= 28;
}

/**
 * The purchase order, from erp.purchase_order_document()'s payload as an issue
 * froze it. Throws PurchaseOrderDocumentError for a payload it cannot draw.
 */
export async function renderPurchaseOrderPdf(payload: unknown): Promise<Uint8Array> {
  const p = dict(payload);
  if (!p) throw new PurchaseOrderDocumentError("the payload is not an object");
  if (p["kind"] !== "purchase_order") {
    throw new PurchaseOrderDocumentError(`${String(p["kind"])} is not a purchase order`);
  }
  const header = dict(p["header"]);
  const company = dict(p["company"]);
  const supplier = dict(p["customer"]);
  const delivery = dict(p["delivery"]);
  const totalsRow = dict(p["totals"]);
  const number = need(header, "number", "the order");
  const currency = need(header, "currency", "the order");
  const supplierName = need(supplier, "legal_name", "the supplier");
  if (!company) throw new PurchaseOrderDocumentError("the order has no company");
  if (!totalsRow) throw new PurchaseOrderDocumentError("the order has no totals");
  const lines = linesOf(p);
  if (lines.length === 0) throw new PurchaseOrderDocumentError("the order has no lines");

  const pdf = await PDFDocument.create();
  pdf.registerFontkit(fontkit);
  const regular = await pdf.embedFont(fontBytes(NOTO_SANS_REGULAR_BASE64), { subset: true });
  const bold = await pdf.embedFont(fontBytes(NOTO_SANS_BOLD_BASE64), { subset: true });
  const sheet = new Sheet(pdf, regular, bold);
  sheet.addPage();

  letterhead(sheet, company, delivery);

  const facts: Array<[string, string]> = [["Order", number]];
  const ordered = longDate(header?.["order_date"]);
  if (ordered) facts.push(["Date", ordered]);
  const required = longDate(header?.["required_date"]);
  if (required) facts.push(["Required by", required]);
  const yours = str(header?.["their_reference"]);
  if (yours) facts.push(["Your reference", yours]);
  const buyer = dict(p["buyer"]);
  const buyerName = str(buyer?.["name"]);
  if (buyerName) facts.push(["Buyer", buyerName]);

  const extra: Array<[string, string]> = [];
  const supplierAddress = addressLines(supplier?.["address"]);
  if (supplierAddress.length > 0) extra.push(["Address", supplierAddress.join(", ")]);
  titleBlock(sheet, "Purchase order", { caption: "To", name: supplierName, extra }, facts);

  const reason = str(p["reason"]);
  if (reason) {
    sheet.paragraph(`This replaces the copy of ${number} sent earlier: ${reason}`, {
      font: sheet.bold,
      color: INK,
    });
    sheet.y -= 6;
  }
  const message = str(p["message"]);
  if (message) {
    sheet.paragraph(message, { color: MUTED });
    sheet.y -= 8;
  }

  table(
    sheet,
    [
      { heading: "Item", width: WIDTH - 260, align: "left" },
      { heading: "Qty", width: 70, align: "right" },
      { heading: "Unit price", width: 90, align: "right" },
      { heading: "Net", width: 100, align: "right" },
    ],
    lines.map((l) => {
      const notes: string[] = [];
      const code = str(l["item_code"]);
      const theirs = str(l["supplier_item_code"]);
      if (theirs) notes.push(`Your code ${theirs}`);
      if (code) notes.push(`Our code ${code}`);
      const due = longDate(l["required_date"]);
      if (due) notes.push(`Required by ${due}`);
      const uom = str(l["uom"]);
      return {
        cells: [
          str(l["description"]) ?? code ?? "Item",
          uom ? `${quantityWords(l["quantity"])} ${uom}` : quantityWords(l["quantity"]),
          money(l["unit_price_minor"], currency),
          money(l["net_minor"], currency),
        ],
        notes,
      };
    }),
  );

  const tax = num(totalsRow["tax_minor"]) ?? 0;
  totals(sheet, [
    ["Net", money(totalsRow["net_minor"], currency), false],
    ...(tax !== 0
      ? ([["Tax", money(tax, currency), false]] as Array<[string, string, boolean]>)
      : []),
    ["Total", money(totalsRow["gross_minor"] ?? totalsRow["net_minor"], currency), true],
  ]);

  sheet.ensure(90);
  heading(sheet, "Delivery and invoicing");
  const site = str(delivery?.["site"]);
  const where = addressLines(delivery?.["address"]);
  if (site || where.length > 0) {
    sheet.paragraph(`Deliver to ${[site, ...where].filter(Boolean).join(", ")}.`);
  }
  sheet.paragraph(
    `Please quote ${number} on your delivery note and your invoice, and send the invoice to ${need(company, "legal_name", "the company")}.`,
    { color: MUTED },
  );
  const buyerEmail = str(buyer?.["email"]);
  if (buyerEmail) {
    sheet.paragraph(
      `Questions about this order: ${buyerName ? `${buyerName}, ` : ""}${buyerEmail}.`,
      {
        color: MUTED,
      },
    );
  }

  const sender = need(company, "legal_name", "the company");
  const label = `Purchase order ${number}`;
  const pages = pdf.getPages();
  pages.forEach((page, index) => {
    page.drawLine({
      start: { x: MARGIN, y: FOOTER_Y + 14 },
      end: { x: RIGHT, y: FOOTER_Y + 14 },
      thickness: 0.6,
      color: RULE,
    });
    page.drawText(printable(`${sender} · ${label}`), {
      x: MARGIN,
      y: FOOTER_Y,
      size: 7.5,
      font: regular,
      color: MUTED,
    });
    const pageLabel = `Page ${index + 1} of ${pages.length}`;
    page.drawText(pageLabel, {
      x: RIGHT - regular.widthOfTextAtSize(pageLabel, 7.5),
      y: FOOTER_Y,
      size: 7.5,
      font: regular,
      color: MUTED,
    });
  });

  // One payload, one set of bytes: the dates are the issue date's.
  const on = str(p["issued_on"]) ?? str(header?.["order_date"]);
  const when =
    on && /^\d{4}-\d{2}-\d{2}/.test(on) ? new Date(`${on.slice(0, 10)}T00:00:00Z`) : new Date(0);
  pdf.setTitle(label);
  pdf.setAuthor(sender);
  pdf.setCreator("Clove ERP");
  pdf.setProducer("Clove ERP");
  pdf.setCreationDate(when);
  pdf.setModificationDate(when);

  return await pdf.save({ useObjectStreams: false });
}
