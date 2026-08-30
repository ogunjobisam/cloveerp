import { describe, expect, test } from "bun:test";

import { formatMinor, minorUnitsOf, toMinor, type Currency } from "./money";

/**
 * The first test in this repository's front end.
 *
 * It exists because writing it found two real bugs in the file it tests,
 * within a minute of running: `toMinor("")` returned 0 rather than null, so an
 * untouched price field would have written a price of nothing to the ledger;
 * and `toMinor("1.005", 2)` returned 100 rather than 101, because
 * `1.005 * 100` is `100.49999999999999`. The second one was contradicted by
 * that function's own doc comment, which is the more embarrassing half.
 *
 * Money is the right place to start: it is the one part of the client that can
 * put a wrong number into an accounting system rather than merely show one.
 */

const currencies: Currency[] = [
  { code: "GBP", name: "Pound sterling", minor_units: 2 },
  { code: "JPY", name: "Japanese yen", minor_units: 0 },
  { code: "KRW", name: "South Korean won", minor_units: 0 },
];

describe("the exponent comes from the currency, not from 100", () => {
  test("a currency with two places", () => expect(minorUnitsOf(currencies, "GBP")).toBe(2));
  test("a currency with none", () => expect(minorUnitsOf(currencies, "JPY")).toBe(0));
  test("an unknown code falls back to two", () => expect(minorUnitsOf(currencies, "XXX")).toBe(2));
  test("so does no code at all", () => expect(minorUnitsOf(currencies, null)).toBe(2));
  test("and so does an absent list, while it loads", () =>
    expect(minorUnitsOf(undefined, "JPY")).toBe(2));
});

describe("display", () => {
  test("two-place currencies are unchanged by the fix", () =>
    expect(formatMinor(100000, "GBP", 2)).toContain("1,000.00"));

  // The bug this file exists for: the old code divided by 100 unconditionally,
  // so ¥100,000 rendered as ¥1,000.00 — a hundredth of the real amount, with
  // decimals a yen does not have.
  test("a zero-place currency is not divided by a hundred", () =>
    expect(formatMinor(100000, "JPY", 0)).toContain("100,000"));
  test("and is given no decimal places", () =>
    expect(formatMinor(100, "JPY", 0)).not.toContain("."));

  test("a malformed code still shows the number", () =>
    expect(formatMinor(12345, "ZZZZ", 2)).toBe("123.45 ZZZZ"));
  test("a null amount is zero rather than blank", () =>
    expect(formatMinor(null, "GBP", 2)).toContain("0.00"));
});

describe("input, which is the direction that writes to the ledger", () => {
  test("major to minor", () => expect(toMinor("10.50", 2)).toBe(1050));
  test("a zero-place currency is not multiplied by a hundred", () =>
    expect(toMinor("1000", 0)).toBe(1000));

  test("rounds rather than truncating, despite the float", () =>
    expect(toMinor("1.005", 2)).toBe(101));
  test("and does not leak representation error", () => expect(toMinor("19.99", 2)).toBe(1999));

  test("nonsense refuses instead of sending NaN", () => expect(toMinor("abc", 2)).toBeNull());

  // An untouched field is an absent answer. Only a typed 0 is a zero.
  test("blank refuses instead of meaning zero", () => expect(toMinor("", 2)).toBeNull());
  test("and so does whitespace", () => expect(toMinor("   ", 2)).toBeNull());
  test("but a typed zero is a zero", () => expect(toMinor("0", 2)).toBe(0));
});
