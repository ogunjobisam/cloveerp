/**
 * The sales-invoice renderer.
 *
 * pdf-lib 1.17.1 with @pdf-lib/fontkit 1.1.1. It was chosen because it is pure
 * JavaScript with no native binary, no headless browser and no filesystem
 * dependency, so the same module runs in the Edge Function, in the test runner
 * and in the Worker. Three things had to be true before a template format was
 * written around it, and each is proved by an executed fixture in
 * invoice-pdf.test.ts:
 *
 *   1. a two-hundred line invoice paginates without clipping, and the tax
 *      summary and totals sit together on the final page — a new page is
 *      started when the reserved closing block will not fit;
 *   2. embedded subset Noto Sans renders the sterling sign and non-ASCII
 *      party names (pdf-lib's standard fonts are WinAnsi only, so fontkit and
 *      an embedded TrueType face are what make this true);
 *   3. "Page N of M" is written in a second pass, once the final page count is
 *      known.
 *
 * Input is the frozen contract produced by erp.sales_invoice_contract, never
 * live records — the renderer is given what was issued, not what is current.
 */
import { PDFDocument, degrees, rgb, type PDFFont, type PDFPage } from "pdf-lib";
import fontkit from "@pdf-lib/fontkit";
import { NOTO_SANS_BOLD_BASE64, NOTO_SANS_REGULAR_BASE64, fontBytes } from "./fonts.ts";

export interface InvoiceContractLine {
  line_no?: number | null;
  item_code?: string | null;
  description?: string | null;
  quantity?: number | string | null;
  unit?: string | null;
  unit_price_minor?: number | null;
  net_minor?: number | null;
  tax_rate_pct?: number | string | null;
  tax_minor?: number | null;
}

export interface InvoiceContract {
  header?: Record<string, unknown>;
  company?: Record<string, unknown>;
  customer?: Record<string, unknown>;
  lines?: InvoiceContractLine[];
  tax_summary?: Array<Record<string, unknown>>;
  totals?: Record<string, unknown>;
  terminology?: Record<string, string>;
}

export interface RenderOptions {
  /** Issued number, or nothing at all for a preview of a draft. */
  issuedNumber?: string | undefined;
  /** Diagonal watermark. Previews always carry one. */
  watermark?: string | undefined;
}

const A4: [number, number] = [595.28, 841.89];
const MARGIN = 44;
const LINE_HEIGHT = 15;
/** Height reserved so the tax summary and totals never split across pages. */
const CLOSING_BLOCK = 150;
const FOOTER_Y = 30;

const COLUMNS = [
  { key: "line", x: MARGIN, width: 26, align: "left" as const },
  { key: "code", x: MARGIN + 28, width: 66, align: "left" as const },
  { key: "description", x: MARGIN + 98, width: 176, align: "left" as const },
  { key: "quantity", x: MARGIN + 278, width: 46, align: "right" as const },
  { key: "unit", x: MARGIN + 328, width: 32, align: "left" as const },
  { key: "price", x: MARGIN + 362, width: 58, align: "right" as const },
  { key: "vat", x: MARGIN + 424, width: 34, align: "right" as const },
  { key: "net", x: MARGIN + 462, width: 66, align: "right" as const },
];

function text(value: unknown): string {
  return value === null || value === undefined ? "" : String(value);
}

export function formatMinor(minor: unknown, currency: string): string {
  const n = Number(minor ?? 0) / 100;
  const symbol = currency === "GBP" ? "\u00A3" : currency === "EUR" ? "\u20AC" : "";
  const body = n.toLocaleString("en-GB", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return symbol ? `${symbol}${body}` : `${body} ${currency}`;
}

function clip(font: PDFFont, value: string, size: number, width: number): string {
  let out = value;
  while (out.length > 1 && font.widthOfTextAtSize(out, size) > width) {
    out = out.slice(0, -1);
  }
  return out.length < value.length ? `${out.slice(0, -1)}\u2026` : out;
}

function draw(
  page: PDFPage,
  font: PDFFont,
  value: string,
  x: number,
  y: number,
  size: number,
  opts?: { width?: number; align?: "left" | "right" },
) {
  const width = opts?.width;
  const shown = width ? clip(font, value, size, width) : value;
  const offset = opts?.align === "right" && width ? width - font.widthOfTextAtSize(shown, size) : 0;
  page.drawText(shown, { x: x + offset, y, size, font });
}

/** Renders the frozen contract and returns the exact bytes to be stored. */
export async function renderSalesInvoicePdf(
  contract: InvoiceContract,
  options: RenderOptions = {},
): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  pdf.registerFontkit(fontkit);
  const regular = await pdf.embedFont(fontBytes(NOTO_SANS_REGULAR_BASE64), { subset: true });
  const bold = await pdf.embedFont(fontBytes(NOTO_SANS_BOLD_BASE64), { subset: true });

  const header = contract.header ?? {};
  const company = contract.company ?? {};
  const customer = contract.customer ?? {};
  const totals = contract.totals ?? {};
  const term = contract.terminology ?? {};
  const currency = text(totals["currency"] ?? header["currency"] ?? "GBP");
  const title = term["document.invoice_reference"] ?? "Invoice";
  const lines = contract.lines ?? [];
  const taxSummary = contract.tax_summary ?? [];

  let page = pdf.addPage(A4);
  let y = 0;

  const startPage = (first: boolean) => {
    page = first ? page : pdf.addPage(A4);
    y = A4[1] - MARGIN;

    if (first) {
      draw(page, bold, title, MARGIN, y, 20);
      draw(
        page,
        bold,
        text(options.issuedNumber ?? header["document_number"]),
        MARGIN + 340,
        y,
        14,
        {
          width: A4[0] - MARGIN * 2 - 340,
          align: "right",
        },
      );
      y -= 26;
      draw(page, bold, text(company["legal_name"]), MARGIN, y, 10);
      draw(
        page,
        regular,
        `${text(term["document.date"] ?? "Date")}: ${text(header["document_date"])}`,
        MARGIN + 340,
        y,
        9,
        { width: 211, align: "right" },
      );
      y -= 13;
      const office = (company["registered_office"] ?? {}) as Record<string, unknown>;
      const officeLines = Array.isArray(office["lines"]) ? (office["lines"] as string[]) : [];
      for (const l of [...officeLines, text(office["locality"]), text(office["postcode"])]) {
        if (!l) continue;
        draw(page, regular, l, MARGIN, y, 9, { width: 240 });
        y -= 11;
      }
      draw(
        page,
        regular,
        `Company number ${text(company["company_registration_number"])}`,
        MARGIN,
        y,
        9,
      );
      y -= 11;
      if (company["vat_registration_number"]) {
        draw(page, regular, `VAT number ${text(company["vat_registration_number"])}`, MARGIN, y, 9);
        y -= 11;
      }
      y -= 8;
      draw(page, bold, text(customer["legal_name"]), MARGIN, y, 10);
      y -= 13;
      const addr = (customer["invoice_address"] ?? {}) as Record<string, unknown>;
      const addrLines = Array.isArray(addr["lines"]) ? (addr["lines"] as string[]) : [];
      for (const l of [...addrLines, text(addr["locality"]), text(addr["postcode"])]) {
        if (!l) continue;
        draw(page, regular, l, MARGIN, y, 9, { width: 240 });
        y -= 11;
      }
      y -= 10;
      draw(
        page,
        regular,
        `${text(term["document.tax_point"] ?? "Tax point")}: ${text(header["tax_point"])}`,
        MARGIN,
        y,
        9,
      );
      y -= 18;
    }

    const headings: Record<string, string> = {
      line: "#",
      code: "Code",
      description: "Description",
      quantity: "Qty",
      unit: "Unit",
      price: "Price",
      vat: "VAT %",
      net: "Net",
    };
    for (const c of COLUMNS) {
      draw(page, bold, headings[c.key] ?? "", c.x, y, 8, { width: c.width, align: c.align });
    }
    y -= 6;
    page.drawLine({
      start: { x: MARGIN, y },
      end: { x: A4[0] - MARGIN, y },
      thickness: 0.6,
      color: rgb(0.6, 0.63, 0.68),
    });
    y -= LINE_HEIGHT;
  };

  startPage(true);

  const remaining = () => y - (FOOTER_Y + 14);

  for (const line of lines) {
    if (remaining() < LINE_HEIGHT) startPage(false);
    const cells: Record<string, string> = {
      line: text(line.line_no),
      code: text(line.item_code),
      description: text(line.description),
      quantity: text(line.quantity),
      unit: text(line.unit),
      price: formatMinor(line.unit_price_minor, currency),
      vat: text(line.tax_rate_pct),
      net: formatMinor(line.net_minor, currency),
    };
    for (const c of COLUMNS) {
      draw(page, regular, cells[c.key] ?? "", c.x, y, 8.5, { width: c.width, align: c.align });
    }
    y -= LINE_HEIGHT;
  }

  // The closing block travels as one. If it will not fit whole, it starts a
  // page of its own rather than leaving the totals orphaned.
  if (remaining() < CLOSING_BLOCK) {
    page = pdf.addPage(A4);
    y = A4[1] - MARGIN;
  }

  y -= 6;
  draw(page, bold, text(term["document.tax_summary"] ?? "VAT summary"), MARGIN, y, 9);
  y -= 14;
  for (const row of taxSummary) {
    draw(
      page,
      regular,
      `${text(row["tax_code"] ?? "")} ${text(row["tax_rate_pct"])}%`,
      MARGIN,
      y,
      8.5,
      { width: 120 },
    );
    draw(page, regular, formatMinor(row["net_minor"], currency), MARGIN + 300, y, 8.5, {
      width: 90,
      align: "right",
    });
    draw(page, regular, formatMinor(row["tax_minor"], currency), MARGIN + 400, y, 8.5, {
      width: 108,
      align: "right",
    });
    y -= 13;
  }

  y -= 8;
  const totalRows: Array<[string, unknown, boolean]> = [
    [text(term["document.net_total"] ?? "Net"), totals["net_minor"], false],
    [text(term["document.tax_total"] ?? "VAT"), totals["tax_minor"], false],
    ["VAT total in sterling", totals["vat_total_sterling_minor"], false],
    [text(term["document.gross_total"] ?? "Total"), totals["gross_minor"], true],
  ];
  for (const [label, value, strong] of totalRows) {
    const f = strong ? bold : regular;
    draw(page, f, label, MARGIN + 300, y, strong ? 10 : 9, { width: 120 });
    draw(
      page,
      f,
      formatMinor(value, strong || label !== "VAT total in sterling" ? currency : "GBP"),
      MARGIN + 424,
      y,
      strong ? 10 : 9,
      { width: 84, align: "right" },
    );
    y -= 14;
  }

  // Second pass: the page count is only knowable now.
  const pages = pdf.getPages();
  pages.forEach((p, index) => {
    const label = `Page ${index + 1} of ${pages.length}`;
    draw(p, regular, label, A4[0] - MARGIN - 100, FOOTER_Y, 8, { width: 100, align: "right" });
    draw(p, regular, text(options.issuedNumber ?? header["document_number"]), MARGIN, FOOTER_Y, 8, {
      width: 240,
    });
    if (options.watermark) {
      p.drawText(options.watermark, {
        x: 90,
        y: 260,
        size: 64,
        font: bold,
        color: rgb(0.85, 0.87, 0.9),
        opacity: 0.45,
        rotate: degrees(38),
      });
    }
  });

  return await pdf.save();
}

/** SHA-256 of the exact bytes, lower-case hex — the checksum of record. */
export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as unknown as ArrayBuffer);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
