/**
 * The order form and the invoice, rendered from fixture payloads shaped as
 * erp.commercial_email_payload() shapes them, and read back with pdf.js.
 */
import { describe, expect, test } from "bun:test";
import { getDocument } from "pdfjs-dist/legacy/build/pdf.mjs";

import {
  CommercialDocumentError,
  commercialDocumentFilename,
  commercialDocumentPath,
  pdfToBase64,
  renderCommercialDocumentPdf,
  sha256Hex,
} from "./commercial-document.ts";

const LETTERHEAD = {
  legal_name: "Example Supplier Ltd",
  registered_address: "1 Example Street\nExampletown EX1 1EX",
  company_number: "00000000",
};

export function orderFormPayload(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    kind: "order_form",
    document_number: "CQ-000123",
    quote_version: 2,
    customer_name: "Okafor Foods Ltd",
    recipient_name: "Dana Okafor",
    currency: "GBP",
    lines: [
      {
        line_no: 10,
        item_code: "PLAN-STANDARD",
        description: "Standard plan",
        quantity: 1,
        unit_price_minor: 1314000,
        discount_pct: 10,
        unit_net_minor: 1182600,
        net_minor: 1182600,
        charge: "recurring",
      },
      {
        line_no: 20,
        item_code: "USER-STANDARD",
        description: "Extra full user, Standard",
        quantity: 10,
        unit_price_minor: 58800,
        discount_pct: 5,
        unit_net_minor: 55860,
        net_minor: 558600,
        charge: "recurring",
      },
      {
        line_no: 30,
        item_code: "ONBOARD-GUIDED",
        description: "Guided onboarding",
        quantity: 1,
        unit_price_minor: 250000,
        discount_pct: 0,
        unit_net_minor: 250000,
        net_minor: 250000,
        charge: "one_off",
      },
    ],
    totals: {
      list_minor: 2152000,
      discount_minor: 160800,
      net_minor: 1991200,
      recurring_minor: 1741200,
      one_off_minor: 250000,
    },
    term_kind: "annual",
    term_months: 12,
    valid_until: "2026-10-14",
    price_book: "CLOVE-LIST v1",
    issued_at: "2026-09-14T10:15:00.123456+00:00",
    issued_on: "2026-09-14",
    letterhead: LETTERHEAD,
    filename: "Order-form-CQ-000123-v2.pdf",
    issuer_email: "sam@cloveerp.com",
    ...over,
  };
}

export function invoicePayload(
  lineCount = 2,
  over: Record<string, unknown> = {},
): Record<string, unknown> {
  const extra = Array.from({ length: Math.max(lineCount - 2, 0) }, (_, i) => ({
    kind: "overage",
    entitlement_code: "documents_per_month",
    unit: "documents",
    month: `2026-${String((i % 12) + 1).padStart(2, "0")}-01`,
    used: 60000 + i,
    limit_value: 50000,
    over: 10000 + i,
    unit_minor: 10,
    band: "DOCS-100K",
    net_minor: 100000 + i,
    unpriced: false,
  }));
  return {
    kind: "contract_invoice",
    reference: "INV-OKAFOR-202609-001",
    customer_name: "Okafor Foods Ltd",
    supplier_name: "Clove ERP Ltd",
    recipient_name: "Accounts Team",
    currency: "GBP",
    period_start: "2026-09-14",
    period_end: "2026-10-14",
    issued_on: "2026-09-14",
    due_on: "2026-09-28",
    lines: [
      {
        kind: "subscription",
        description: "standard plan, 2026-09-14 to 2026-10-14",
        net_minor: 145100,
      },
      {
        kind: "one_off",
        item_code: "ONBOARD-GUIDED",
        description: "Guided onboarding",
        quantity: 1,
        net_minor: 250000,
      },
      ...extra,
    ],
    subscription_minor: 145100,
    overage_minor: 0,
    one_off_minor: 250000,
    recurring_minor: 145100,
    total_minor: 395100,
    tax_statement: "Clove ERP Ltd is not registered for VAT; no VAT is charged.",
    payment_details: {
      legal_name: "Example Supplier Ltd",
      registered_address: "1 Example Street",
      company_number: "00000000",
      bank_account_name: "Example Supplier Ltd",
      sort_code: "00-00-00",
      account_number: "00000000",
      payment_reference_guidance: "Use the reference exactly as it is written.",
    },
    letterhead: LETTERHEAD,
    filename: "Invoice-INV-OKAFOR-202609-001.pdf",
    issuer_email: "sam@cloveerp.com",
    ...over,
  };
}

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

describe("the order form as a PDF", () => {
  test("is a one-page PDF with the letterhead, the quote, the customer, the term and the dates", async () => {
    const bytes = await renderCommercialDocumentPdf(orderFormPayload());
    expect(new TextDecoder().decode(bytes.slice(0, 5))).toBe("%PDF-");
    const pages = await pageTexts(bytes);
    expect(pages).toHaveLength(1);
    const text = pages[0]!;
    for (const expected of [
      "Clove ERP",
      "Example Supplier Ltd",
      "1 Example Street",
      "Exampletown EX1 1EX",
      "Company number 00000000",
      "Order form",
      "CQ-000123",
      "Version",
      "14 September 2026",
      "14 October 2026",
      "Okafor Foods Ltd",
      "PREPARED FOR",
      "TERM",
      "12 months, billed yearly",
      "Page 1 of 1",
    ]) {
      expect(text).toContain(expected);
    }
  });

  test("shows each item's quantity, list price, discount and net, then the recurring and one-off totals", async () => {
    const text = (await pageTexts(await renderCommercialDocumentPdf(orderFormPayload()))).join(" ");
    for (const expected of [
      "Item",
      "List price",
      "Discount",
      "Standard plan",
      "£13,140.00",
      "10%",
      "£11,826.00",
      "Extra full user, Standard",
      "£588.00",
      "5%",
      "£5,586.00",
      "Guided onboarding",
      "Charged once",
      "Recurring",
      "£17,412.00",
      "One-off",
      "£2,500.00",
      "Total",
      "£19,912.00",
    ]) {
      expect(text).toContain(expected);
    }
  });

  test("closes with a signature block for the customer", async () => {
    const text = (await pageTexts(await renderCommercialDocumentPdf(orderFormPayload()))).join(" ");
    expect(text).toContain("Signed for and on behalf of Okafor Foods Ltd");
    for (const caption of ["Signature", "Name", "Position", "Date"])
      expect(text).toContain(caption);
  });

  test("never prints a cost or a margin, whatever else the payload carries", async () => {
    const bytes = await renderCommercialDocumentPdf(
      orderFormPayload({
        totals: {
          ...(orderFormPayload()["totals"] as object),
          cost_minor: 450000,
          margin_pct: 62.5,
        },
      }),
    );
    const text = (await pageTexts(bytes)).join(" ").toLowerCase();
    expect(text).not.toContain("cost");
    expect(text).not.toContain("margin");
    expect(text).not.toContain("4,500");
  });

  test("leaves out letterhead lines that are not set rather than inventing them", async () => {
    const text = (
      await pageTexts(await renderCommercialDocumentPdf(orderFormPayload({ letterhead: null })))
    ).join(" ");
    expect(text).toContain("Clove ERP");
    expect(text).not.toContain("Company number");
    expect(text).not.toContain("Example Supplier Ltd");
  });

  test("one payload renders to one set of bytes", async () => {
    const one = await renderCommercialDocumentPdf(orderFormPayload());
    const two = await renderCommercialDocumentPdf(orderFormPayload());
    expect(await sha256Hex(one)).toBe(await sha256Hex(two));
    expect(await sha256Hex(one)).toMatch(/^[0-9a-f]{64}$/);
  });

  test("a customer's accented name prints as written", async () => {
    const text = (
      await pageTexts(
        await renderCommercialDocumentPdf(
          orderFormPayload({ customer_name: "Société Générale Ünïcode Ltd" }),
        ),
      )
    ).join(" ");
    expect(text).toContain("Société Générale Ünïcode Ltd");
  });
});

describe("the invoice as a PDF", () => {
  test("carries the reference, the dates, the lines, the total, the VAT statement and how to pay", async () => {
    const bytes = await renderCommercialDocumentPdf(invoicePayload());
    expect(new TextDecoder().decode(bytes.slice(0, 5))).toBe("%PDF-");
    const pages = await pageTexts(bytes);
    expect(pages).toHaveLength(1);
    const text = pages[0]!;
    for (const expected of [
      "Clove ERP",
      "Example Supplier Ltd",
      "Invoice",
      "INV-OKAFOR-202609-001",
      "Issued",
      "14 September 2026",
      "Due",
      "28 September 2026",
      "14 September 2026 to 14 October 2026",
      "BILLED TO",
      "PERIOD",
      "Okafor Foods Ltd",
      "standard plan, 2026-09-14 to 2026-10-14",
      "£1,451.00",
      "Guided onboarding",
      "£2,500.00",
      "Total",
      "£3,951.00",
      "Clove ERP Ltd is not registered for VAT; no VAT is charged.",
      "How to pay",
      "Please pay by 28 September 2026.",
      "Account name",
      "Sort code",
      "00-00-00",
      "Account number",
      "Please quote INV-OKAFOR-202609-001.",
      "Use the reference exactly as it is written.",
      "Page 1 of 1",
    ]) {
      expect(text).toContain(expected);
    }
    expect(text).not.toMatch(/VAT £|VAT \d/);
  });

  test("without payment details it says they will follow, and still asks for the reference", async () => {
    const text = (
      await pageTexts(
        await renderCommercialDocumentPdf(invoicePayload(2, { payment_details: null })),
      )
    ).join(" ");
    expect(text).toContain("Payment details will follow from our accounts team.");
    expect(text).toContain("Please quote INV-OKAFOR-202609-001.");
    expect(text).not.toContain("Sort code");
  });

  test("a sixty-line invoice flows over pages, repeats its column headings and ends with the total and how to pay", async () => {
    const bytes = await renderCommercialDocumentPdf(invoicePayload(60));
    const pages = await pageTexts(bytes);
    expect(pages.length).toBeGreaterThan(1);
    for (const [i, page] of pages.entries()) {
      expect(page).toContain(`Page ${i + 1} of ${pages.length}`);
      expect(page).toContain("Invoice INV-OKAFOR-202609-001");
    }
    for (const page of pages.slice(1)) {
      if (page.includes("Over the limit")) expect(page).toContain("Amount");
    }
    const all = pages.join(" ");
    expect(all.match(/Over the limit on documents per month/g)?.length).toBe(58);
    expect(pages.at(-1)).toContain("How to pay");
    expect(pages.at(-1)).toContain("Please quote INV-OKAFOR-202609-001.");
    expect(all).toContain("60,057 used against 50,000");
  });

  test("an invoice without a due date, a total or a VAT statement is refused", async () => {
    for (const broken of [{ due_on: null }, { total_minor: null }, { tax_statement: "" }]) {
      await expect(renderCommercialDocumentPdf(invoicePayload(2, broken))).rejects.toBeInstanceOf(
        CommercialDocumentError,
      );
    }
    await expect(renderCommercialDocumentPdf({ kind: "receipt" })).rejects.toBeInstanceOf(
      CommercialDocumentError,
    );
    await expect(
      renderCommercialDocumentPdf(orderFormPayload({ lines: [] })),
    ).rejects.toBeInstanceOf(CommercialDocumentError);
  });
});

describe("a reminder for an unpaid invoice", () => {
  test("draws the invoice it chases, to the same bytes, under the invoice's own name", async () => {
    const invoiceBytes = await renderCommercialDocumentPdf(invoicePayload());
    const reminderBytes = await renderCommercialDocumentPdf(
      invoicePayload(2, { kind: "invoice_reminder", reminder_number: 2, days_overdue: 8 }),
    );
    expect(await sha256Hex(reminderBytes)).toBe(await sha256Hex(invoiceBytes));
    const text = (await pageTexts(reminderBytes)).join(" ");
    expect(text).toContain("Invoice");
    expect(text).not.toContain("overdue");
    expect(text).not.toContain("reminder");
    expect(
      commercialDocumentFilename(invoicePayload(2, { kind: "invoice_reminder", filename: null })),
    ).toBe("Invoice-INV-OKAFOR-202609-001.pdf");
  });

  test("keeps its own copy, under its own kind", () => {
    const id = "0b5a1e3c-5d6f-4a7b-8c9d-0e1f2a3b4c5d";
    expect(commercialDocumentPath("invoice_reminder", id)).toBe(
      `commercial/invoice-reminder/${id}.pdf`,
    );
    expect(() => commercialDocumentPath("receipt", id)).toThrow(CommercialDocumentError);
  });
});

describe("the file around the document", () => {
  test("is named as the database names it, or as it would", () => {
    expect(commercialDocumentFilename(orderFormPayload())).toBe("Order-form-CQ-000123-v2.pdf");
    expect(commercialDocumentFilename(invoicePayload())).toBe("Invoice-INV-OKAFOR-202609-001.pdf");
    expect(commercialDocumentFilename(orderFormPayload({ filename: null }))).toBe(
      "Order-form-CQ-000123-v2.pdf",
    );
    expect(commercialDocumentFilename(invoicePayload(2, { filename: "../../etc/passwd" }))).toBe(
      "Invoice-INV-OKAFOR-202609-001.pdf",
    );
  });

  test("is kept under the path its settle will accept", () => {
    const id = "0b5a1e3c-5d6f-4a7b-8c9d-0e1f2a3b4c5d";
    expect(commercialDocumentPath("order_form", id)).toBe(`commercial/order-form/${id}.pdf`);
    expect(commercialDocumentPath("contract_invoice", id)).toBe(
      `commercial/contract-invoice/${id}.pdf`,
    );
    expect(() => commercialDocumentPath("order_form", "../x")).toThrow(CommercialDocumentError);
  });

  test("goes as base64 that decodes to the same bytes", async () => {
    const bytes = await renderCommercialDocumentPdf(invoicePayload());
    const decoded = Uint8Array.from(atob(pdfToBase64(bytes)), (c) => c.charCodeAt(0));
    expect(await sha256Hex(decoded)).toBe(await sha256Hex(bytes));
  });
});
