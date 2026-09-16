/**
 * An issued order form or contract invoice, as a PDF document.
 *
 * The dispatch drain emails every issued order form and contract invoice
 * (20260914097300) and attaches this document to the email, keeping a copy in
 * the private document-output bucket (20260915020000). Its only input is the
 * payload erp.commercial_email_payload() hands the drain: the order form's
 * price as it was issued, or the invoice as it was issued, with the platform's
 * letterhead and payment details as the owner set them. It reads nothing else,
 * so what the document says is exactly what the email says, and a cost or a
 * margin cannot reach it: the payload never carries one, and this file names
 * every field it prints.
 *
 * pdf-lib with an embedded subset of Noto Sans through fontkit, as the sales
 * invoice renderer (invoice-pdf.ts) does, so the sterling sign and a customer's
 * accented name print, and the same bytes come out under Bun, Deno and Vite.
 * The document's dates are the issue date, so one payload renders to one set
 * of bytes, and its checksum means something.
 *
 * Imports only pdf-lib, fontkit, the fonts beside it and the money formatter,
 * by relative paths with their extensions, so the dispatch Edge Function can
 * follow them.
 */
import { PDFDocument, rgb, type PDFFont, type PDFPage, type RGB } from "pdf-lib";
import fontkit from "@pdf-lib/fontkit";
import { NOTO_SANS_BOLD_BASE64, NOTO_SANS_REGULAR_BASE64, fontBytes } from "./fonts.ts";
import { formatMinor } from "../money.ts";

export type CommercialDocumentKind = "order_form" | "contract_invoice" | "invoice_reminder";

/**
 * A reminder carries the invoice it chases (20260915070000), so it draws the
 * same document from the same figures: what the customer is asked to pay is
 * the invoice, and a second piece of paper saying something slightly different
 * is how a dispute starts.
 */
function documentKind(kind: unknown): "order_form" | "contract_invoice" | null {
  if (kind === "order_form") return "order_form";
  if (kind === "contract_invoice" || kind === "invoice_reminder") return "contract_invoice";
  return null;
}

/** A payload this file cannot make a document of. The message says what was wrong. */
export class CommercialDocumentError extends Error {}

const PAGE: [number, number] = [595.28, 841.89];
const MARGIN = 50;
const RIGHT = PAGE[0] - MARGIN;
const WIDTH = RIGHT - MARGIN;
const FOOTER_Y = 30;
/** Nothing is drawn below this line except the footer. */
const FLOOR = FOOTER_Y + 34;

const INK = rgb(0.25, 0.23, 0.21);
const MUTED = rgb(0.4, 0.38, 0.36);
const BRAND = rgb(0.21, 0.19, 0.17);
const ACCENT = rgb(0.64, 0.35, 0.12);
const RULE = rgb(0.86, 0.84, 0.81);
const SHADE = rgb(0.965, 0.957, 0.94);

type Dict = Record<string, unknown>;

function dict(value: unknown): Dict | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Dict)
    : null;
}

function str(value: unknown): string | null {
  if (typeof value === "string") return value.trim() === "" ? null : value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return null;
}

function num(value: unknown): number | null {
  const n = typeof value === "string" && value.trim() !== "" ? Number(value) : value;
  return typeof n === "number" && Number.isFinite(n) ? n : null;
}

function need(d: Dict, key: string, what: string): string {
  const value = str(d[key]);
  if (value === null) throw new CommercialDocumentError(`${what} has no ${key}`);
  return value;
}

/** Minor units as money, through the formatter every screen uses. */
export function money(minor: unknown, currency: string): string {
  const n = num(minor);
  return formatMinor(n ?? 0, currency, 2);
}

/** "14 September 2026", from a date or an instant, never shifted by a zone. */
export function longDate(value: unknown): string | null {
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

function termWords(kind: unknown, months: unknown): string | null {
  const m = num(months);
  switch (kind) {
    case "annual":
      return "12 months, billed yearly";
    case "monthly":
      return "Month to month, billed monthly";
    case "multi_year":
      return m !== null && m >= 24
        ? `${Math.round(m / 12)} years, billed yearly`
        : "Several years, billed yearly";
    default:
      return null;
  }
}

function quantityWords(value: unknown): string {
  const n = num(value);
  if (n === null) return "1";
  return Number.isInteger(n) ? n.toLocaleString("en-GB") : String(Number(n.toFixed(4)));
}

/** One line of text: control characters, line breaks included, become spaces. */
function printable(value: string): string {
  return [...value]
    .map((c) => (c.charCodeAt(0) < 32 || c.charCodeAt(0) === 127 ? " " : c))
    .join("");
}

/** Words onto lines no wider than width; a word wider than a line is broken. */
export function wrapText(font: PDFFont, value: string, size: number, width: number): string[] {
  const lines: string[] = [];
  for (const paragraph of value.split(/\r?\n/)) {
    const words = printable(paragraph)
      .split(/\s+/)
      .filter((w) => w.length > 0);
    if (words.length === 0) {
      lines.push("");
      continue;
    }
    let line = "";
    for (const word of words) {
      const candidate = line ? `${line} ${word}` : word;
      if (font.widthOfTextAtSize(candidate, size) <= width) {
        line = candidate;
        continue;
      }
      if (line) lines.push(line);
      if (font.widthOfTextAtSize(word, size) <= width) {
        line = word;
        continue;
      }
      let piece = "";
      for (const ch of word) {
        if (font.widthOfTextAtSize(piece + ch, size) > width && piece) {
          lines.push(piece);
          piece = ch;
        } else {
          piece += ch;
        }
      }
      line = piece;
    }
    lines.push(line);
  }
  return lines;
}

/** The name the PDF is attached and downloaded under, as the database decides it. */
export function commercialDocumentFilename(payload: unknown, kind?: string | null): string {
  const p = dict(payload) ?? {};
  const given = str(p["filename"]);
  if (given && /^[A-Za-z0-9._-]+\.pdf$/.test(given)) return given;
  const safe = (v: string) => v.replace(/[^A-Za-z0-9-]+/g, "-");
  if (documentKind(p["kind"] ?? kind) === "order_form") {
    return `Order-form-${safe(str(p["document_number"]) ?? "quote")}-v${str(p["quote_version"]) ?? "1"}.pdf`;
  }
  return `Invoice-${safe(str(p["reference"]) ?? "invoice")}.pdf`;
}

/** Where the drain keeps the copy of one send's PDF in the document-output bucket. */
export function commercialDocumentPath(kind: string, emailId: string): string {
  if (!/^[0-9a-f-]{36}$/.test(emailId))
    throw new CommercialDocumentError(`${emailId} is not an email id`);
  if (documentKind(kind) === null) throw new CommercialDocumentError(`${kind} keeps no document`);
  return `commercial/${kind.replace(/_/g, "-")}/${emailId}.pdf`;
}

/** Bytes as base64, for an email attachment. */
export function pdfToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

/** SHA-256 of the exact bytes, lower-case hex: the checksum the copy is recorded with. */
export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as unknown as ArrayBuffer);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/* -------------------------------------------------------------------------- */
/* Drawing                                                                    */
/* -------------------------------------------------------------------------- */

type Align = "left" | "right";

class Sheet {
  page!: PDFPage;
  y = 0;
  onNewPage: (() => void) | null = null;

  constructor(
    readonly pdf: PDFDocument,
    readonly regular: PDFFont,
    readonly bold: PDFFont,
  ) {}

  addPage(): void {
    this.page = this.pdf.addPage(PAGE);
    this.y = PAGE[1] - MARGIN;
  }

  /** Room for height below the cursor, or a new page with whatever it repeats. */
  ensure(height: number): void {
    if (this.y - height >= FLOOR) return;
    this.addPage();
    this.onNewPage?.();
  }

  text(
    value: string,
    x: number,
    y: number,
    opts: { size?: number; font?: PDFFont; color?: RGB; width?: number; align?: Align } = {},
  ): void {
    const size = opts.size ?? 9;
    const font = opts.font ?? this.regular;
    const shown = printable(value);
    const w = font.widthOfTextAtSize(shown, size);
    const x0 = opts.align === "right" && opts.width !== undefined ? x + opts.width - w : x;
    this.page.drawText(shown, { x: x0, y, size, font, color: opts.color ?? INK });
  }

  rule(y: number, x1 = MARGIN, x2 = RIGHT, color: RGB = RULE, thickness = 0.7): void {
    this.page.drawLine({ start: { x: x1, y }, end: { x: x2, y }, thickness, color });
  }

  /** A paragraph from the cursor down, flowing onto new pages. */
  paragraph(
    value: string,
    opts: { size?: number; font?: PDFFont; color?: RGB; x?: number; width?: number } = {},
  ): void {
    const size = opts.size ?? 9;
    const font = opts.font ?? this.regular;
    const lead = size * 1.45;
    for (const line of wrapText(font, value, size, opts.width ?? WIDTH)) {
      this.ensure(lead);
      this.text(line, opts.x ?? MARGIN, this.y - size, { size, font, color: opts.color ?? INK });
      this.y -= lead;
    }
  }
}

type Column = { heading: string; width: number; align: Align };

function letterhead(sheet: Sheet, payload: Dict): void {
  const head = dict(payload["letterhead"]) ?? {};
  const top = sheet.y;
  sheet.text("Clove ERP", MARGIN, top - 22, { size: 24, font: sheet.bold, color: BRAND });

  // Who sent it, as the owner set it: every line that is set, and none invented.
  const lines: Array<{ value: string; bold: boolean }> = [];
  const name = str(head["legal_name"]);
  if (name) lines.push({ value: name, bold: true });
  const address = str(head["registered_address"]);
  if (address) {
    for (const l of address.split(/\r?\n|,\s*/)) {
      if (l.trim()) lines.push({ value: l.trim(), bold: false });
    }
  }
  const number = str(head["company_number"]);
  if (number) lines.push({ value: `Company number ${number}`, bold: false });

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

function titleBlock(
  sheet: Sheet,
  title: string,
  party: { caption: string; name: string; extra: Array<[string, string]> },
  facts: Array<[string, string]>,
): void {
  const top = sheet.y;
  sheet.text(title, MARGIN, top - 20, { size: 22, font: sheet.bold, color: BRAND });

  let left = top - 46;
  sheet.text(party.caption.toUpperCase(), MARGIN, left, {
    size: 7.5,
    font: sheet.bold,
    color: MUTED,
  });
  left -= 14;
  for (const piece of wrapText(sheet.bold, party.name, 11, 250)) {
    sheet.text(piece, MARGIN, left, { size: 11, font: sheet.bold });
    left -= 14;
  }
  for (const [caption, value] of party.extra) {
    left -= 4;
    sheet.text(caption.toUpperCase(), MARGIN, left, { size: 7.5, font: sheet.bold, color: MUTED });
    left -= 12;
    for (const piece of wrapText(sheet.regular, value, 9, 250)) {
      sheet.text(piece, MARGIN, left, { size: 9 });
      left -= 12;
    }
  }

  let right = top - 18;
  const labelX = RIGHT - 230;
  for (const [caption, value] of facts) {
    sheet.text(caption, labelX, right, { size: 8.5, color: MUTED });
    sheet.text(value, labelX + 80, right, {
      size: 9,
      font: sheet.bold,
      width: 150,
      align: "right",
    });
    right -= 15;
  }
  sheet.y = Math.min(left, right) - 18;
}

function table(
  sheet: Sheet,
  columns: Column[],
  rows: Array<{ cells: string[]; notes: string[] }>,
): void {
  const size = 8.8;
  const lead = 12;
  const xs: number[] = [];
  let x = MARGIN;
  for (const c of columns) {
    xs.push(x);
    x += c.width;
  }

  const header = () => {
    sheet.ensure(24);
    sheet.page.drawRectangle({
      x: MARGIN,
      y: sheet.y - 17,
      width: WIDTH,
      height: 20,
      color: SHADE,
    });
    columns.forEach((c, i) => {
      sheet.text(c.heading, (xs[i] ?? MARGIN) + 6, sheet.y - 11, {
        size: 8,
        font: sheet.bold,
        color: MUTED,
        width: c.width - 12,
        align: c.align,
      });
    });
    sheet.y -= 24;
  };

  sheet.onNewPage = header;
  header();

  for (const row of rows) {
    const first = columns[0]!;
    const wrapped = wrapText(sheet.regular, row.cells[0] ?? "", size, first.width - 12);
    const notes = row.notes.flatMap((n) => wrapText(sheet.regular, n, 7.5, first.width - 12));
    const height = wrapped.length * lead + notes.length * 10 + 8;
    sheet.ensure(height);
    let y = sheet.y - size;
    wrapped.forEach((line, i) => {
      sheet.text(line, (xs[0] ?? MARGIN) + 6, y - i * lead, { size, width: first.width - 12 });
    });
    columns.slice(1).forEach((c, i) => {
      sheet.text(row.cells[i + 1] ?? "", (xs[i + 1] ?? MARGIN) + 6, y, {
        size,
        width: c.width - 12,
        align: c.align,
      });
    });
    y -= wrapped.length * lead;
    for (const note of notes) {
      sheet.text(note, (xs[0] ?? MARGIN) + 6, y + 2, { size: 7.5, color: MUTED });
      y -= 10;
    }
    sheet.y -= height;
    sheet.rule(sheet.y + 3);
  }
  sheet.onNewPage = null;
  sheet.y -= 10;
}

function totals(sheet: Sheet, rows: Array<[string, string, boolean]>): void {
  sheet.ensure(rows.length * 24 + 10);
  for (const [caption, value, strong] of rows) {
    const font = strong ? sheet.bold : sheet.regular;
    const size = strong ? 11 : 9.5;
    if (strong) {
      sheet.rule(sheet.y - 2, RIGHT - 230, RIGHT, INK, 0.9);
      sheet.y -= 8;
    }
    sheet.text(caption, RIGHT - 230, sheet.y - size, { size, font, color: strong ? INK : MUTED });
    sheet.text(value, RIGHT - 130, sheet.y - size, { size, font, width: 130, align: "right" });
    sheet.y -= strong ? 20 : 16;
  }
  sheet.y -= 10;
}

function heading(sheet: Sheet, value: string): void {
  sheet.ensure(40);
  sheet.text(value, MARGIN, sheet.y - 12, { size: 12, font: sheet.bold, color: BRAND });
  sheet.y -= 22;
}

/* -------------------------------------------------------------------------- */
/* The two documents                                                          */
/* -------------------------------------------------------------------------- */

function linesOf(payload: Dict): Dict[] {
  const lines = payload["lines"];
  if (!Array.isArray(lines)) throw new CommercialDocumentError("the payload has no lines");
  return lines.map((l, i) => {
    const d = dict(l);
    if (!d) throw new CommercialDocumentError(`line ${i + 1} is not an object`);
    return d;
  });
}

function orderForm(sheet: Sheet, payload: Dict): string {
  const number = need(payload, "document_number", "the order form");
  const customer = need(payload, "customer_name", "the order form");
  const currency = need(payload, "currency", "the order form");
  const version = str(payload["quote_version"]) ?? "1";
  const totalsRow = dict(payload["totals"]);
  if (!totalsRow) throw new CommercialDocumentError("the order form has no totals");
  const lines = linesOf(payload);
  if (lines.length === 0) throw new CommercialDocumentError("the order form has no lines");
  const net = num(totalsRow["net_minor"]);
  if (net === null) throw new CommercialDocumentError("the order form has no total");

  letterhead(sheet, payload);
  const term = termWords(payload["term_kind"], payload["term_months"]);
  const facts: Array<[string, string]> = [
    ["Quote", number],
    ["Version", version],
  ];
  const issued = longDate(payload["issued_on"] ?? payload["issued_at"]);
  if (issued) facts.push(["Issued", issued]);
  const valid = longDate(payload["valid_until"]);
  if (valid) facts.push(["Valid until", valid]);
  titleBlock(
    sheet,
    "Order form",
    { caption: "Prepared for", name: customer, extra: term ? [["Term", term]] : [] },
    facts,
  );

  table(
    sheet,
    [
      { heading: "Item", width: WIDTH - 280, align: "left" },
      { heading: "Qty", width: 40, align: "right" },
      { heading: "List price", width: 85, align: "right" },
      { heading: "Discount", width: 60, align: "right" },
      { heading: "Net", width: 95, align: "right" },
    ],
    lines.map((l) => {
      const discount = num(l["discount_pct"]) ?? 0;
      const notes: string[] = [];
      const code = str(l["item_code"]);
      if (code) notes.push(code);
      if (l["charge"] === "one_off") notes.push("Charged once");
      return {
        cells: [
          str(l["description"]) ?? code ?? "Item",
          quantityWords(l["quantity"]),
          money(l["unit_price_minor"], currency),
          discount > 0 ? `${Number(discount.toFixed(2))}%` : "—",
          money(l["net_minor"], currency),
        ],
        notes,
      };
    }),
  );

  totals(sheet, [
    ["Recurring", money(totalsRow["recurring_minor"], currency), false],
    ["One-off", money(totalsRow["one_off_minor"], currency), false],
    ["Total", money(net, currency), true],
  ]);

  // The acceptance travels as one: it starts a page of its own rather than
  // splitting its lines across two.
  sheet.ensure(190);
  heading(sheet, "Acceptance");
  sheet.paragraph(
    `By signing, ${customer} accepts this order form at the prices above${valid ? `, which are valid until ${valid}` : ""}.`,
    { color: MUTED },
  );
  sheet.y -= 6;
  sheet.text(`Signed for and on behalf of ${customer}`, MARGIN, sheet.y - 10, {
    size: 10,
    font: sheet.bold,
  });
  sheet.y -= 34;
  for (const caption of ["Signature", "Name", "Position", "Date"]) {
    sheet.rule(sheet.y, MARGIN + 70, MARGIN + 330, INK, 0.6);
    sheet.text(caption, MARGIN, sheet.y + 3, { size: 9, color: MUTED });
    sheet.y -= 30;
  }

  return `Order form ${number} v${version}`;
}

function invoiceLine(l: Dict): { label: string; notes: string[] } {
  switch (l["kind"]) {
    case "subscription":
      return { label: str(l["description"]) ?? "Subscription", notes: [] };
    case "one_off":
      return { label: str(l["description"]) ?? "One-off charge", notes: ["Charged once"] };
    case "overage": {
      const what = (str(l["entitlement_code"]) ?? "usage").replaceAll("_", " ");
      const month = longDate(l["month"]);
      const used = num(l["used"]);
      const limit = num(l["limit_value"]);
      return {
        label: `Over the limit on ${what}${month ? `, ${month.replace(/^\d+ /, "")}` : ""}`,
        notes:
          used !== null && limit !== null
            ? [`${used.toLocaleString("en-GB")} used against ${limit.toLocaleString("en-GB")}`]
            : [],
      };
    }
    default:
      return { label: str(l["description"]) ?? "Charge", notes: [] };
  }
}

function invoice(sheet: Sheet, payload: Dict): string {
  const reference = need(payload, "reference", "the invoice");
  const customer = need(payload, "customer_name", "the invoice");
  const currency = need(payload, "currency", "the invoice");
  const due = longDate(payload["due_on"]);
  if (!due) throw new CommercialDocumentError("the invoice has no due date");
  const total = num(payload["total_minor"]);
  if (total === null) throw new CommercialDocumentError("the invoice has no total");
  const statement = str(payload["tax_statement"]);
  if (!statement) throw new CommercialDocumentError("the invoice has no VAT statement");
  const lines = linesOf(payload);

  letterhead(sheet, payload);
  const facts: Array<[string, string]> = [["Reference", reference]];
  const issued = longDate(payload["issued_on"]);
  if (issued) facts.push(["Issued", issued]);
  facts.push(["Due", due]);
  const start = longDate(payload["period_start"]);
  const end = longDate(payload["period_end"]);
  titleBlock(
    sheet,
    "Invoice",
    {
      caption: "Billed to",
      name: customer,
      extra: start && end ? [["Period", `${start} to ${end}`]] : [],
    },
    facts,
  );

  table(
    sheet,
    [
      { heading: "Description", width: WIDTH - 130, align: "left" },
      { heading: "Amount", width: 130, align: "right" },
    ],
    lines.map((l) => {
      const shaped = invoiceLine(l);
      return { cells: [shaped.label, money(l["net_minor"], currency)], notes: shaped.notes };
    }),
  );

  totals(sheet, [["Total", money(total, currency), true]]);

  sheet.ensure(40);
  sheet.paragraph(statement, { color: MUTED });
  sheet.y -= 14;

  // How to pay travels as one.
  const pay = dict(payload["payment_details"]);
  const account = pay ? str(pay["bank_account_name"]) : null;
  const sort = pay ? str(pay["sort_code"]) : null;
  const number = pay ? str(pay["account_number"]) : null;
  sheet.ensure(130);
  heading(sheet, "How to pay");
  sheet.paragraph(`Please pay by ${due}.`);
  if (account && sort && number) {
    sheet.y -= 4;
    const boxTop = sheet.y;
    const rows: Array<[string, string]> = [
      ["Account name", account],
      ["Sort code", sort],
      ["Account number", number],
    ];
    sheet.page.drawRectangle({
      x: MARGIN,
      y: boxTop - rows.length * 16 - 12,
      width: 300,
      height: rows.length * 16 + 12,
      color: SHADE,
    });
    let y = boxTop - 16;
    for (const [caption, value] of rows) {
      sheet.text(caption, MARGIN + 12, y, { size: 9, color: MUTED });
      sheet.text(value, MARGIN + 120, y, { size: 10, font: sheet.bold });
      y -= 16;
    }
    sheet.y = boxTop - rows.length * 16 - 24;
  } else {
    sheet.paragraph("Payment details will follow from our accounts team.");
  }
  sheet.paragraph(`Please quote ${reference}.`, { font: sheet.bold });
  const guidance = pay ? str(pay["payment_reference_guidance"]) : null;
  if (guidance) sheet.paragraph(guidance, { color: MUTED });

  return `Invoice ${reference}`;
}

/**
 * The PDF of one claimed commercial email's payload. Throws
 * CommercialDocumentError for a payload it cannot read; the drain then sends
 * the email without it and records why.
 */
export async function renderCommercialDocumentPdf(payload: unknown): Promise<Uint8Array> {
  const p = dict(payload);
  if (!p) throw new CommercialDocumentError("the payload is not an object");
  const kind = documentKind(p["kind"]);
  if (kind === null) {
    throw new CommercialDocumentError(`${String(p["kind"])} is not an order form or an invoice`);
  }

  const pdf = await PDFDocument.create();
  pdf.registerFontkit(fontkit);
  const regular = await pdf.embedFont(fontBytes(NOTO_SANS_REGULAR_BASE64), { subset: true });
  const bold = await pdf.embedFont(fontBytes(NOTO_SANS_BOLD_BASE64), { subset: true });
  const sheet = new Sheet(pdf, regular, bold);
  sheet.addPage();

  const label = kind === "order_form" ? orderForm(sheet, p) : invoice(sheet, p);

  // The footer, once the page count is known.
  const sender = str(dict(p["letterhead"])?.["legal_name"]) ?? "Clove ERP";
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
  const on = str(kind === "order_form" ? (p["issued_on"] ?? p["issued_at"]) : p["issued_on"]);
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
