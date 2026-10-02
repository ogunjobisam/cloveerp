import { describe, expect, test } from "bun:test";

import { purchaseOrderPayload } from "../pdf/test-fixtures.ts";
import {
  DocumentEmailError,
  composePurchaseOrderEmail,
  namedSender,
  type ClaimedDocumentEmail,
} from "./purchase-order-email.ts";

/** A send as erp.claim_document_email_batch() hands it to the drain (20261004920000). */
const row = (over: Partial<ClaimedDocumentEmail> = {}): ClaimedDocumentEmail => ({
  id: "0f8b6b52-6b0e-4d3a-9b7e-1d2c3a4b5c6d",
  document_kind: "purchase_order",
  to_address: "orders@maison.example",
  to_name: "Paul Purchasing",
  cc_addresses: [],
  from_address: "no-reply@cloveerp.com",
  from_name: "Okafor Retail Ltd",
  reply_to: "bea@okafor.example",
  message: "Please confirm the delivery date.",
  idempotency_key: "k1",
  attempt: 1,
  issued_number: "PO-000042",
  organisation_name: "Okafor Retail",
  payload: purchaseOrderPayload(),
  ...over,
});

describe("the email a supplier receives with a purchase order", () => {
  test("names the order in the subject, says it is attached, and gives the figures and the buyer's message", () => {
    const email = composePurchaseOrderEmail(row(), { attachment: "Purchase-order-PO-000042.pdf" });
    expect(email.subject).toBe("Purchase order PO-000042");
    expect(email.text).toContain("Okafor Retail Ltd has placed order PO-000042 with you.");
    expect(email.text).toContain("attached as a PDF, Purchase-order-PO-000042.pdf");
    expect(email.text).toContain("£2,592.00");
    expect(email.text).toContain("Please confirm the delivery date.");
    expect(email.text).toContain("Hello Paul Purchasing,");
    expect(email.html).toContain("mailto:bea@okafor.example");
  });

  test("without a PDF it never points at an attachment", () => {
    const email = composePurchaseOrderEmail(row());
    expect(email.text).not.toContain("attached");
    expect(email.text).toContain("Reply if you need it as a PDF.");
  });

  test("a second send says so in the subject and says why", () => {
    const email = composePurchaseOrderEmail(
      row({ payload: purchaseOrderPayload({ reason: "line 1 is now 14" }) }),
    );
    expect(email.subject).toBe("Purchase order PO-000042, sent again");
    expect(email.text).toContain("This copy replaces the one sent earlier: line 1 is now 14");
  });

  test("escapes what the organisation typed", () => {
    const email = composePurchaseOrderEmail(row({ message: "<script>alert(1)</script>" }));
    expect(email.html).not.toContain("<script>");
  });

  test("something other than a purchase order, or a payload without its number or totals, is refused", () => {
    expect(() => composePurchaseOrderEmail(row({ document_kind: "invoice" }))).toThrow(
      DocumentEmailError,
    );
    expect(() =>
      composePurchaseOrderEmail(row({ payload: { kind: "purchase_order" }, issued_number: "" })),
    ).toThrow(DocumentEmailError);
  });

  test("the sender carries the organisation's name, cleaned of what a display name may not hold", () => {
    expect(namedSender("Okafor Retail Ltd", "no-reply@cloveerp.com")).toBe(
      '"Okafor Retail Ltd" <no-reply@cloveerp.com>',
    );
    expect(namedSender('Bad "Name" <x>', "a@b.example")).toBe('"Bad Name x" <a@b.example>');
    expect(namedSender(null, "a@b.example")).toBe("a@b.example");
  });
});
