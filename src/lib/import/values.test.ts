import { describe, expect, test } from "bun:test";

import {
  countryToIso2,
  decimalText,
  deriveCode,
  normaliseVat,
  parseDecimal,
  parseMinor,
  parseQuantity,
  parseUkDate,
  roundTo,
} from "./values";

const minor = (text: string) => {
  const r = parseMinor(text);
  return r.ok ? r.minor : r.reason;
};

describe("money is read from its digits, never through a float", () => {
  test("the forms a report prints", () => {
    expect(minor("1234.50")).toBe(123450);
    expect(minor("£1,234.50")).toBe(123450);
    expect(minor("(123.45)")).toBe(-12345);
    expect(minor("-1234.5")).toBe(-123450);
    expect(minor("123.45-")).toBe(-12345);
    expect(minor("1,234")).toBe(123400);
    expect(minor(" 0.07 ")).toBe(7);
    expect(minor(".5")).toBe(50);
    expect(minor("GBP 10.00")).toBe(1000);
  });

  test("the classic float traps are exact", () => {
    expect(minor("1.005")).toBe("too_many_places");
    expect(minor("0.29")).toBe(29);
    expect(minor("4.35")).toBe(435);
    expect(minor("1.10")).toBe(110);
  });

  test("trailing zeros past two places are not a problem", () => {
    expect(minor("12.3400")).toBe(1234);
  });

  test("what is not money is refused", () => {
    expect(minor("")).toBe("blank");
    expect(minor("abc")).toBe("not_a_number");
    expect(minor("1,23")).toBe("not_a_number");
    expect(minor("1.2.3")).toBe("not_a_number");
    expect(minor("-")).toBe("not_a_number");
    expect(minor("99999999999999999")).toBe("too_large");
  });
});

describe("decimals and rounding", () => {
  test("half away from zero, as a report rounds", () => {
    expect(roundTo({ units: 4350n, scale: 3 }, 2)).toBe(435n);
    expect(roundTo({ units: 4355n, scale: 3 }, 2)).toBe(436n);
    expect(roundTo({ units: -4355n, scale: 3 }, 2)).toBe(-436n);
  });

  test("quantities keep their fractions as text", () => {
    expect(parseQuantity("12.50")).toBe("12.5");
    expect(parseQuantity("1,000")).toBe("1000");
    expect(parseQuantity("-0.250")).toBe("-0.25");
    expect(parseQuantity("x")).toBeNull();
  });

  test("canonical text", () => {
    const d = parseDecimal("0.0400");
    expect(d && decimalText(d)).toBe("0.04");
  });
});

describe("UK dates, day first, always", () => {
  test("the forms Xero and Unleashed print", () => {
    expect(parseUkDate("30/09/2026")).toBe("2026-09-30");
    expect(parseUkDate("3/10/26")).toBe("2026-10-03");
    expect(parseUkDate("30 Sep 2026")).toBe("2026-09-30");
    expect(parseUkDate("30-Sep-26")).toBe("2026-09-30");
    expect(parseUkDate("30 September 2026")).toBe("2026-09-30");
    expect(parseUkDate("1 Sept 2026")).toBe("2026-09-01");
    expect(parseUkDate("2026-09-30")).toBe("2026-09-30");
    expect(parseUkDate("2026-09-30T00:00:00")).toBe("2026-09-30");
  });

  test("dates that do not exist are refused", () => {
    expect(parseUkDate("31/02/2026")).toBeNull();
    expect(parseUkDate("29/02/2027")).toBeNull();
    expect(parseUkDate("13/13/2026")).toBeNull();
    expect(parseUkDate("30 Septembre 2026")).toBeNull();
    expect(parseUkDate("yesterday")).toBeNull();
  });

  test("a leap day that exists", () => expect(parseUkDate("29/02/2028")).toBe("2028-02-29"));
});

describe("countries", () => {
  test("names, codes and the UK's many names", () => {
    expect(countryToIso2("United Kingdom")).toBe("GB");
    expect(countryToIso2("UK")).toBe("GB");
    expect(countryToIso2("England")).toBe("GB");
    expect(countryToIso2("scotland")).toBe("GB");
    expect(countryToIso2("Ireland")).toBe("IE");
    expect(countryToIso2("Australia")).toBe("AU");
    expect(countryToIso2("de")).toBe("DE");
    expect(countryToIso2("USA")).toBe("US");
  });

  test("an unknown country is null, not a guess", () => {
    expect(countryToIso2("Atlantis")).toBeNull();
    expect(countryToIso2("")).toBeNull();
  });
});

describe("derived party codes (D5)", () => {
  test("upper case, letters and digits, twenty characters", () => {
    expect(deriveCode("Hamilton Smith Ltd", new Set())).toBe("HAMILTONSMITHLTD");
    expect(deriveCode("The Very Long Company Name Limited", new Set())).toBe(
      "THEVERYLONGCOMPANYNA",
    );
    expect(deriveCode("—", new Set())).toBe("PARTY");
  });

  test("a collision takes a suffix and stays within twenty", () => {
    const taken = new Set<string>();
    expect(deriveCode("The Very Long Company Name Limited", taken)).toBe("THEVERYLONGCOMPANYNA");
    expect(deriveCode("The Very Long Company Name Ltd", taken)).toBe("THEVERYLONGCOMPANYN2");
    expect(deriveCode("The Very Long Company Name plc", taken)).toBe("THEVERYLONGCOMPANYN3");
  });
});

describe("VAT numbers", () => {
  test("HMRC's forms", () => {
    expect(normaliseVat("GB 123 4567 89")).toEqual({ value: "GB123456789", wellFormed: true });
    expect(normaliseVat("123456789")).toEqual({ value: "GB123456789", wellFormed: true });
    expect(normaliseVat("GB123456789001")).toEqual({ value: "GB123456789001", wellFormed: true });
    expect(normaliseVat("GBGD001")).toEqual({ value: "GBGD001", wellFormed: true });
    expect(normaliseVat("XI123456789")).toEqual({ value: "XI123456789", wellFormed: true });
  });

  test("anything else is kept as typed and flagged", () => {
    expect(normaliseVat("GB12345")).toEqual({ value: "GB12345", wellFormed: false });
    expect(normaliseVat("IE6388047V")).toEqual({ value: "IE6388047V", wellFormed: false });
    expect(normaliseVat("  ")).toBeNull();
  });
});
