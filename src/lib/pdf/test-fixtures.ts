/**
 * What the purchase order's tests share (20261004920000): a payload shaped as
 * erp.purchase_order_document() shapes it, and the text of a rendered PDF read
 * back with pdf.js. Imported by tests only; nothing in the application reads it.
 */
import { getDocument } from "pdfjs-dist/legacy/build/pdf.mjs";

/** The text of each page, in reading order, whitespace collapsed. */
export async function pageTexts(bytes: Uint8Array): Promise<string[]> {
  const task = getDocument({ data: bytes.slice(), useWorkerFetch: false, isEvalSupported: false });
  const doc = await task.promise;
  const pages: string[] = [];
  for (let n = 1; n <= doc.numPages; n += 1) {
    const page = await doc.getPage(n);
    const content = await page.getTextContent();
    pages.push(
      content.items
        .map((item) => ("str" in item ? item.str : ""))
        .join(" ")
        .replace(/\s+/g, " "),
    );
  }
  await doc.destroy();
  return pages;
}

export function purchaseOrderPayload(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    kind: "purchase_order",
    issued_on: "2026-10-01",
    header: {
      number: "PO-000042",
      order_date: "2026-10-01",
      required_date: "2026-10-15",
      currency: "GBP",
      our_reference: null,
      their_reference: "PF-0042",
    },
    company: {
      name: "Okafor Retail",
      legal_name: "Okafor Retail Ltd",
      registration_number: "01234567",
      country_code: "GB",
    },
    delivery: {
      site: "Main warehouse",
      address: { line1: "Unit 4, Dock Road", city: "Tilbury", postcode: "RM18 7AA" },
    },
    customer: {
      code: "MAISON",
      name: "Maison Brand",
      legal_name: "Maison Brand SARL",
      address: { line1: "12 rue du Faubourg", city: "Paris", country: "France" },
    },
    lines: [
      {
        line_no: 10,
        item_code: "COAT-NAVY-M",
        description: "Wool coat, navy, medium",
        supplier_item_code: "MB-7781",
        quantity: 12,
        uom: "EA",
        unit_price_minor: 18000,
        net_minor: 216000,
        tax_code: "S",
        tax_minor: 43200,
        required_date: null,
      },
    ],
    tax_summary: [{ tax_code: "S", net_minor: 216000, tax_minor: 43200 }],
    totals: { net_minor: 216000, tax_minor: 43200, gross_minor: 259200 },
    buyer: { name: "Bea Buyer", email: "bea@okafor.example" },
    message: "Please confirm the delivery date.",
    reason: null,
    ...over,
  };
}
