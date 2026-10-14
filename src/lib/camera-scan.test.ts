import { describe, expect, test } from "bun:test";

import { cameraScan } from "./camera-scan";
import type { ApplicationIdentifier } from "./gs1";

/** The six identifiers erp_ref.gs1_application_identifier ships, verbatim. */
const REGISTER: ApplicationIdentifier[] = [
  { ai: "00", field_name: "sscc", data_length: 18, is_numeric: true },
  { ai: "01", field_name: "gtin", data_length: 14, is_numeric: true },
  { ai: "10", field_name: "batch", data_length: null, is_numeric: false },
  { ai: "17", field_name: "expiry", data_length: 6, is_numeric: true },
  { ai: "21", field_name: "serial", data_length: null, is_numeric: false },
  { ai: "37", field_name: "count", data_length: null, is_numeric: true },
];
const KNOWN = ["gs1_128", "gs1_datamatrix", "ean_13", "upc_a", "code_128", "code_39"];
const GS = "\u001d";

describe("what a camera read is, in the product's symbologies", () => {
  test("Code 128 carrying application identifiers is GS1-128", () => {
    // GTIN, expiry 31 December 2026, batch B42.
    expect(
      cameraScan(
        { format: "code_128", rawValue: "01050123456789001726123110B42" },
        REGISTER,
        KNOWN,
      ),
    ).toEqual({
      raw: "01050123456789001726123110B42",
      symbology: "gs1_128",
    });
  });

  test("Code 128 that is not GS1 is plain Code 128, as an internal label is", () => {
    expect(cameraScan({ format: "code_128", rawValue: "LOC-A01-03" }, REGISTER, KNOWN)).toEqual({
      raw: "LOC-A01-03",
      symbology: "code_128",
    });
  });

  test("a decoder's symbology identifier is believed, and is not part of the barcode", () => {
    expect(
      cameraScan({ format: "code_128", rawValue: "]C100050123456789012345" }, REGISTER, KNOWN),
    ).toEqual({
      raw: "00050123456789012345",
      symbology: "gs1_128",
    });
    expect(cameraScan({ format: "ean_13", rawValue: "]E05012345678900" }, REGISTER, KNOWN)).toEqual(
      {
        raw: "5012345678900",
        symbology: "ean_13",
      },
    );
  });

  test("DataMatrix is GS1 DataMatrix, separators kept for the parser", () => {
    const raw = `0105012345678900${GS}10LOT7${GS}21SN99`;
    expect(cameraScan({ format: "data_matrix", rawValue: raw }, REGISTER, KNOWN)).toEqual({
      raw,
      symbology: "gs1_datamatrix",
    });
  });

  test("retail and legacy formats keep their names", () => {
    expect(
      cameraScan({ format: "upc_a", rawValue: "012345678905" }, REGISTER, KNOWN).symbology,
    ).toBe("upc_a");
    expect(cameraScan({ format: "code_39", rawValue: "ABC123" }, REGISTER, KNOWN).symbology).toBe(
      "code_39",
    );
  });

  test("a format the product does not read is said, not guessed", () => {
    const qr = cameraScan({ format: "qr_code", rawValue: "https://example.com" }, REGISTER, KNOWN);
    expect(qr.symbology).toBeNull();
    expect("why" in qr && qr.why).toBe("a qr code barcode, which this product does not read");
    // Nor a symbology this organisation's register leaves out.
    expect(
      cameraScan({ format: "code_39", rawValue: "X" }, REGISTER, ["gs1_128"]).symbology,
    ).toBeNull();
  });
});
