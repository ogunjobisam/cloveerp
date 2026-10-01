/**
 * The purchase order a supplier receives, rendered from a payload shaped as
 * erp.purchase_order_document() shapes it (20261004920000), and read back.
 */
import { describe, expect, test } from "bun:test";

import { pageTexts, purchaseOrderPayload } from "./test-fixtures.ts";
import {
  PurchaseOrderDocumentError,
  addressLines,
  purchaseOrderFilename,
  purchaseOrderPath,
  renderPurchaseOrderPdf,
} from "./purchase-order-pdf.ts";

describe("the purchase order PDF", () => {
  test("prints the order, the supplier, the line with both codes, the totals and where to deliver", async () => {
    const [page] = await pageTexts(await renderPurchaseOrderPdf(purchaseOrderPayload()));
    for (const expected of [
      "Okafor Retail Ltd",
      "Purchase order",
      "PO-000042",
      "Maison Brand SARL",
      "Wool coat, navy, medium",
      "Your code MB-7781",
      "Our code COAT-NAVY-M",
      "12 EA",
      "£180.00",
      "£2,160.00",
      "£432.00",
      "£2,592.00",
      "Please confirm the delivery date.",
      "Unit 4, Dock Road",
      "Please quote PO-000042",
      "bea@okafor.example",
      "Page 1 of 1",
    ]) {
      expect(page).toContain(expected);
    }
  });

  test("a second send says it replaces the first, and why", async () => {
    const [page] = await pageTexts(
      await renderPurchaseOrderPdf(purchaseOrderPayload({ reason: "line 1 is now 14" })),
    );
    expect(page).toContain("This replaces the copy of PO-000042 sent earlier: line 1 is now 14");
  });

  test("one payload renders to one set of bytes", async () => {
    const a = await renderPurchaseOrderPdf(purchaseOrderPayload());
    const b = await renderPurchaseOrderPdf(purchaseOrderPayload());
    expect(Buffer.from(a).equals(Buffer.from(b))).toBe(true);
  });

  test("a payload that is not a purchase order, or has no lines or number, is refused by name", async () => {
    await expect(renderPurchaseOrderPdf({ kind: "order_form" })).rejects.toBeInstanceOf(
      PurchaseOrderDocumentError,
    );
    await expect(renderPurchaseOrderPdf(purchaseOrderPayload({ lines: [] }))).rejects.toThrow(
      "no lines",
    );
    await expect(
      renderPurchaseOrderPdf(purchaseOrderPayload({ header: { currency: "GBP" } })),
    ).rejects.toThrow("has no number");
  });

  test("names the file after the order and keeps the copy under the send's own id", () => {
    expect(purchaseOrderFilename(purchaseOrderPayload())).toBe("Purchase-order-PO-000042.pdf");
    expect(purchaseOrderPath("0f8b6b52-6b0e-4d3a-9b7e-1d2c3a4b5c6d")).toBe(
      "purchase-order/0f8b6b52-6b0e-4d3a-9b7e-1d2c3a4b5c6d.pdf",
    );
    expect(() => purchaseOrderPath("../../etc/passwd")).toThrow(PurchaseOrderDocumentError);
  });

  test("an address is printed in the usual order, and none is invented", () => {
    expect(addressLines({ postcode: "RM18 7AA", line1: "Unit 4", city: "Tilbury" })).toEqual([
      "Unit 4",
      "Tilbury",
      "RM18 7AA",
    ]);
    expect(addressLines({})).toEqual([]);
    expect(addressLines(null)).toEqual([]);
  });
});
