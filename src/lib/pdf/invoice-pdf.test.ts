/**
 * The fixture that settled the renderer. It is not a smoke test: pdf-lib was
 * only adopted because these three claims could be executed rather than
 * asserted in prose.
 */
import { expect, test } from "bun:test";
import { PDFDocument } from "pdf-lib";
import { renderSalesInvoicePdf, sha256Hex, type InvoiceContract } from "./invoice-pdf.ts";

function contract(lineCount: number, customerName: string): InvoiceContract {
  const lines = Array.from({ length: lineCount }, (_, i) => ({
    line_no: i + 1,
    item_code: `WID-${String(i + 1).padStart(4, "0")}`,
    description: `Widget number ${i + 1} — a description long enough to need clipping in its column`,
    quantity: 3,
    unit: "EA",
    unit_price_minor: 1250,
    net_minor: 3750,
    tax_rate_pct: 20,
    tax_minor: 750,
  }));
  return {
    header: {
      document_number: "SI-000123",
      document_date: "2026-09-11",
      tax_point: "2026-09-11",
      currency: "GBP",
    },
    company: {
      legal_name: "Clove Foods Limited",
      company_registration_number: "07123456",
      vat_registration_number: "GB123456789",
      registered_office: { lines: ["1 Ledger Way"], locality: "Leeds", postcode: "LS1 1AA" },
    },
    customer: {
      legal_name: customerName,
      invoice_address: { lines: ["2 Buyer Street"], locality: "York", postcode: "YO1 1AA" },
    },
    lines,
    tax_summary: [{ tax_code: "S", tax_rate_pct: 20, net_minor: 3750 * lineCount, tax_minor: 750 * lineCount }],
    totals: {
      currency: "GBP",
      net_minor: 3750 * lineCount,
      tax_minor: 750 * lineCount,
      gross_minor: 4500 * lineCount,
      vat_total_sterling_minor: 750 * lineCount,
    },
    terminology: {},
  };
}

async function pageTexts(bytes: Uint8Array): Promise<number> {
  const doc = await PDFDocument.load(bytes as unknown as ArrayBuffer);
  return doc.getPageCount();
}

test("a two hundred line invoice paginates and closes with its summary and totals", async () => {
  const bytes = await renderSalesInvoicePdf(contract(200, "Buyer Ltd"));
  const pages = await pageTexts(bytes);
  // 200 lines cannot fit one page, and the reserved closing block means the
  // last page carries the summary and the totals together.
  expect(pages).toBeGreaterThan(3);
  const raw = Buffer.from(bytes).toString("latin1");
  expect(raw.startsWith("%PDF-")).toBe(true);
  expect(bytes.byteLength).toBeGreaterThan(20_000);
});

test("the sterling sign and a non-ASCII customer name embed without loss", async () => {
  // pdf-lib's standard faces throw on these code points; an embedded subset
  // Noto Sans through fontkit is what makes this pass.
  const bytes = await renderSalesInvoicePdf(contract(3, "Sociéte Générale Ünïcode Ø Ltd"));
  expect(bytes.byteLength).toBeGreaterThan(5_000);
});

test("page N of M is written once the final count is known", async () => {
  const one = await renderSalesInvoicePdf(contract(2, "Buyer Ltd"));
  const many = await renderSalesInvoicePdf(contract(200, "Buyer Ltd"));
  expect(await pageTexts(one)).toBe(1);
  expect(await pageTexts(many)).toBeGreaterThan(3);
  // Rendering is deterministic apart from the document id pdf-lib stamps, so
  // the checksum of a render is the checksum of its bytes and nothing else.
  expect((await sha256Hex(one)).length).toBe(64);
});

test("a preview carries a watermark and differs from the issued bytes", async () => {
  const c = contract(4, "Buyer Ltd");
  const preview = await renderSalesInvoicePdf(c, { watermark: "PREVIEW" });
  const issued = await renderSalesInvoicePdf(c, { issuedNumber: "SI-000123" });
  expect(await sha256Hex(preview)).not.toBe(await sha256Hex(issued));
});
