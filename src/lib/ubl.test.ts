import { describe, expect, test } from "bun:test";

import {
  PEPPOL_BILLING_CUSTOMIZATION_ID,
  PEPPOL_BILLING_PROFILE_ID,
  serializeBillingContract,
  validateBillingContract,
  type BillingContract,
} from "./ubl";

const contract: BillingContract = {
  kind: "sales_invoice",
  number: "INV-000001",
  issueDate: "2026-09-11",
  dueDate: "2026-10-11",
  currency: "GBP",
  buyerReference: "BUYER-1",
  seller: {
    name: "Clove Foods",
    legalName: "Clove Foods Limited",
    registrationNumber: "12345678",
    vatNumber: "GB123456789",
    endpoint: { value: "0192:12345678", schemeId: "0192" },
    address: { lines: ["1 Test Street"], city: "Leeds", postcode: "LS1 1AA", countryCode: "GB" },
  },
  buyer: {
    name: "Buyer & Sons",
    legalName: "Buyer & Sons Limited",
    registrationNumber: "87654321",
    vatNumber: "GB987654321",
    endpoint: { value: "0192:87654321", schemeId: "0192" },
    address: { lines: ["2 Market Road"], city: "York", postcode: "YO1 1AA", countryCode: "GB" },
  },
  payment: {
    meansCode: "30",
    accountId: "GB82WEST12345698765432",
    accountName: "Clove Foods Limited",
  },
  lines: [
    {
      id: "1",
      quantity: "2",
      unitCode: "EA",
      name: "Cloves £",
      price: "10.00",
      netAmount: "20.00",
      taxCategoryCode: "S",
      taxRate: "20",
    },
  ],
  taxes: [{ categoryCode: "S", rate: "20", taxableAmount: "20.00", taxAmount: "4.00" }],
  totals: {
    lineExtension: "20.00",
    taxExclusive: "20.00",
    taxInclusive: "24.00",
    payable: "24.00",
  },
};

describe("Peppol BIS Billing UBL", () => {
  test("declares and escapes a sales invoice", () => {
    const output = serializeBillingContract(contract);
    expect(output).toContain(
      '<Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"',
    );
    expect(output).toContain(
      `<cbc:CustomizationID>${PEPPOL_BILLING_CUSTOMIZATION_ID}</cbc:CustomizationID>`,
    );
    expect(output).toContain(`<cbc:ProfileID>${PEPPOL_BILLING_PROFILE_ID}</cbc:ProfileID>`);
    expect(output).toContain("Buyer &amp; Sons");
    expect(output).toContain("Cloves £");
  });

  test("uses the credit-note root and requires the original invoice", () => {
    const { payment: _payment, ...withoutPayment } = contract;
    const credit: BillingContract = {
      ...withoutPayment,
      kind: "credit_note",
      number: "CRN-000001",
    };
    expect(validateBillingContract(credit).map((failure) => failure.code)).toContain(
      "CLOVEERP_PEPPOL_PRECEDING_INVOICE_REQUIRED",
    );
    credit.precedingInvoiceReference = "INV-000001";
    const output = serializeBillingContract(credit);
    expect(output).toContain(
      '<CreditNote xmlns="urn:oasis:names:specification:ubl:schema:xsd:CreditNote-2"',
    );
    expect(output).toContain("<cbc:CreditNoteTypeCode>381</cbc:CreditNoteTypeCode>");
    expect(output).toContain('<cbc:CreditedQuantity unitCode="EA">2</cbc:CreditedQuantity>');
  });

  test("returns actionable failures before serialization", () => {
    const invalid: BillingContract = {
      ...contract,
      buyer: { ...contract.buyer, endpoint: { value: "", schemeId: "" } },
      lines: [{ ...contract.lines[0]!, unitCode: "", taxCategoryCode: "" }],
    };
    const failures = validateBillingContract(invalid);
    expect(failures.every((failure) => failure.code.startsWith("CLOVEERP_"))).toBe(true);
    expect(failures.some((failure) => failure.fixPath === "/master-data/partners")).toBe(true);
    expect(failures.some((failure) => failure.lineId === "1")).toBe(true);
  });
});
