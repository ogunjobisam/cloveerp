import { describe, expect, test } from "bun:test";

import { evaluateScan, parseGs1, pickRule, plainFields, type ApplicationIdentifier } from "./gs1";

/** The six identifiers erp_ref.gs1_application_identifier ships, verbatim. */
const REGISTER: ApplicationIdentifier[] = [
  { ai: "00", field_name: "sscc", data_length: 18, is_numeric: true },
  { ai: "01", field_name: "gtin", data_length: 14, is_numeric: true },
  { ai: "10", field_name: "batch", data_length: null, is_numeric: false },
  { ai: "17", field_name: "expiry", data_length: 6, is_numeric: true },
  { ai: "21", field_name: "serial", data_length: null, is_numeric: false },
  { ai: "37", field_name: "count", data_length: null, is_numeric: true },
];

const SYMBOLOGIES = [
  { code: "gs1_128", is_gs1: true },
  { code: "gs1_datamatrix", is_gs1: true },
  { code: "ean_13", is_gs1: false },
  { code: "code_128", is_gs1: false },
];

describe("§14.4 the shared parser, mirrored from erp.parse_gs1()", () => {
  test("one scan populates several fields", () => {
    expect(parseGs1("0105012345678900" + "17311231" + "10LOT42\u001d21SER9", REGISTER)).toEqual({
      gtin: "05012345678900",
      expiry: "2031-12-31",
      batch: "LOT42",
      serial: "SER9",
    });
  });

  test("a variable-length field runs to the end when it is last", () => {
    expect(parseGs1("0105012345678900" + "10LOT42", REGISTER)).toEqual({
      gtin: "05012345678900",
      batch: "LOT42",
    });
  });

  test("an expiry day of 00 is the end of the month", () => {
    expect(parseGs1("17260200", REGISTER)).toEqual({ expiry: "2026-02-28" });
    expect(parseGs1("17280200", REGISTER)).toEqual({ expiry: "2028-02-29" });
  });

  test("a leading separator from the scanner is dropped", () => {
    expect(parseGs1("\u001d0105012345678900", REGISTER)).toEqual({ gtin: "05012345678900" });
  });

  test("an unrecognised identifier is rejected with the value shown", () => {
    expect(() => parseGs1("9912345", REGISTER)).toThrow(/ERPWARE_UNRECOGNISED_BARCODE: 9912345/);
  });

  test("a truncated fixed-length field is rejected", () => {
    expect(() => parseGs1("01050123", REGISTER)).toThrow(/ERPWARE_TRUNCATED_BARCODE/);
  });

  test("a numeric field carrying letters is rejected", () => {
    expect(() => parseGs1("01ABCDEFGHIJKLMN", REGISTER)).toThrow(/NOT_NUMERIC/);
  });

  test("nothing scanned is an error, not an empty result", () => {
    expect(() => parseGs1("  ", REGISTER)).toThrow(/ERPWARE_EMPTY_SCAN/);
  });
});

describe("§14.4 legacy and internal marking", () => {
  test("an EAN-13 is offered as a fourteen-digit GTIN", () => {
    expect(plainFields("5012345678900", "ean_13")).toEqual({
      value: "5012345678900",
      gtin: "05012345678900",
    });
  });

  test("a Code 128 is a value and nothing more", () => {
    expect(plainFields("LOC-A-01-03", "code_128")).toEqual({ value: "LOC-A-01-03" });
  });
});

describe("§14.4 scan rules, mirrored from erp.evaluate_scan()", () => {
  const rules = [
    {
      item_class: null,
      accepted_symbologies: ["gs1_128"],
      mandatory_identifiers: ["01", "10"],
      when_absent: "exception_with_reason",
    },
    {
      item_class: "pharma",
      accepted_symbologies: ["gs1_datamatrix"],
      mandatory_identifiers: ["01", "10", "17", "21"],
      when_absent: "refuse",
    },
  ];

  test("the specific rule beats the default", () => {
    expect(pickRule(rules, "pharma")?.item_class).toBe("pharma");
    expect(pickRule(rules, "food")?.item_class).toBeNull();
    expect(pickRule([], "food")).toBeNull();
  });

  test("a complete barcode is accepted", () => {
    const v = evaluateScan({
      barcode: "010501234567890010LOT1",
      symbology: "gs1_128",
      symbologies: SYMBOLOGIES,
      rules,
      register: REGISTER,
    });
    expect(v.outcome).toBe("accepted");
    expect(v.fields["batch"]).toBe("LOT1");
  });

  test("a symbology the step does not accept is refused", () => {
    const v = evaluateScan({
      barcode: "5012345678900",
      symbology: "ean_13",
      symbologies: SYMBOLOGIES,
      rules,
      register: REGISTER,
    });
    expect(v.outcome).toBe("refused");
    expect(v.reason).toMatch(/not accepted/);
  });

  test("a missing mandatory field is an exception with the field named", () => {
    const v = evaluateScan({
      barcode: "0105012345678900",
      symbology: "gs1_128",
      symbologies: SYMBOLOGIES,
      rules,
      register: REGISTER,
    });
    expect(v.outcome).toBe("exception");
    expect(v.missing_identifiers).toEqual(["batch"]);
  });

  test("the pharma rule refuses rather than excepting", () => {
    const v = evaluateScan({
      barcode: "010501234567890010LOT1",
      symbology: "gs1_datamatrix",
      symbologies: SYMBOLOGIES,
      rules,
      itemClass: "pharma",
      register: REGISTER,
    });
    expect(v.outcome).toBe("refused");
    expect(v.missing_identifiers).toEqual(["expiry", "serial"]);
  });

  test("an unreadable barcode is rejected with its value, never silently ignored", () => {
    const v = evaluateScan({
      barcode: "XYZ",
      symbology: "gs1_128",
      symbologies: SYMBOLOGIES,
      rules,
      register: REGISTER,
    });
    expect(v.outcome).toBe("rejected");
    expect(v.scanned_value).toBe("XYZ");
  });

  test("no rule configured accepts and says so", () => {
    const v = evaluateScan({
      barcode: "LOC-1",
      symbology: "code_128",
      symbologies: SYMBOLOGIES,
      rules: [],
      register: REGISTER,
    });
    expect(v.outcome).toBe("accepted");
    expect(v.reason).toMatch(/no scan rule/);
  });

  test("a symbology the product does not read is a client bug, thrown", () => {
    expect(() =>
      evaluateScan({
        barcode: "x",
        symbology: "qr",
        symbologies: SYMBOLOGIES,
        rules,
        register: REGISTER,
      }),
    ).toThrow(/ERPWARE_UNKNOWN_SYMBOLOGY/);
  });
});
