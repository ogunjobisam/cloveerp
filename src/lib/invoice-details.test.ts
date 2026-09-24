import { describe, expect, test } from "bun:test";

import { companyInvoiceDetailsArgs, partyAddressArgs } from "./invoice-details";

describe("invoice details from the desk (20260924200000)", () => {
  test("a company's details: the lines given, and what was left empty sent as nothing", () => {
    expect(
      companyInvoiceDetailsArgs({
        p_entity_code: "MAIN",
        p_registration_number: " 07123456 ",
        office_line_1: "1 Ledger Way",
        office_line_2: "  ",
        p_office_locality: "Leeds",
        p_office_postcode: "LS1 1AA",
        p_vat_number: "",
      }),
    ).toEqual({
      p_entity_code: "MAIN",
      p_registration_number: "07123456",
      p_office_lines: ["1 Ledger Way"],
      p_office_locality: "Leeds",
      p_office_postcode: "LS1 1AA",
      p_office_country_code: null,
      p_vat_number: null,
      p_vat_registered_from: null,
    });
  });

  test("only a VAT number: no office is sent, so the one recorded stays", () => {
    const args = companyInvoiceDetailsArgs({ p_entity_code: "MAIN", p_vat_number: "GB123456789" });
    expect(args["p_office_lines"]).toBeNull();
    expect(args["p_vat_number"]).toBe("GB123456789");
  });

  test("a partner's address: both lines, the kind defaulting to billing", () => {
    expect(
      partyAddressArgs({
        p_party_id: "p-1",
        line_1: "9 New Road",
        line_2: "Unit 4",
        p_locality: "Leeds",
        p_postcode: "LS2 2BB",
        p_country_code: "GB",
      }),
    ).toEqual({
      p_party_id: "p-1",
      p_address_kind: "billing",
      p_lines: ["9 New Road", "Unit 4"],
      p_locality: "Leeds",
      p_postcode: "LS2 2BB",
      p_country_code: "GB",
      p_label: null,
    });
  });
});
