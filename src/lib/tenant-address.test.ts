import { describe, expect, test } from "bun:test";

import {
  addressShaped,
  displayAddress,
  readAddressLookup,
  suggestAddress,
  typedAddress,
} from "./tenant-address";

describe("addressShaped", () => {
  test("holds the database's shape", () => {
    expect(addressShaped("acme")).toBe(true);
    expect(addressShaped("acme-tools-2")).toBe(true);
    expect(addressShaped("a1b")).toBe(true);
  });

  test("refuses what the database refuses", () => {
    expect(addressShaped("ab")).toBe(false);
    expect(addressShaped("-acme")).toBe(false);
    expect(addressShaped("acme-")).toBe(false);
    expect(addressShaped("Acme")).toBe(false);
    expect(addressShaped("acme tools")).toBe(false);
    expect(addressShaped("a".repeat(64))).toBe(false);
    expect(addressShaped("a".repeat(63))).toBe(true);
  });
});

describe("suggestAddress", () => {
  test("drops the legal suffix and joins the words", () => {
    expect(suggestAddress("Acme Manufacturing Ltd")).toBe("acme-manufacturing");
    expect(suggestAddress("Northwind Traders Limited")).toBe("northwind-traders");
  });

  test("keeps a name that is only a suffix", () => {
    expect(suggestAddress("Company")).toBe("company");
  });

  test("folds accents, ampersands and apostrophes", () => {
    expect(suggestAddress("Café Müller & Söhne GmbH")).toBe("cafe-muller-and-sohne");
    expect(suggestAddress("O'Neill's Bakery")).toBe("oneills-bakery");
  });

  test("returns nothing when there is nothing to make one of", () => {
    expect(suggestAddress("  !!  ")).toBe("");
  });

  test("never ends on a hyphen when cut to length", () => {
    const long = `${"a".repeat(62)} b`;
    const suggested = suggestAddress(long);
    expect(suggested.length).toBeLessThanOrEqual(63);
    expect(suggested.endsWith("-")).toBe(false);
  });
});

describe("typedAddress", () => {
  test("keeps only what an address can hold, as it is typed", () => {
    expect(typedAddress("Acme Tools")).toBe("acme-tools");
    expect(typedAddress("acme-")).toBe("acme-");
    expect(typedAddress("a--b")).toBe("a-b");
    expect(typedAddress("acmé!")).toBe("acm");
  });
});

describe("readAddressLookup", () => {
  test("reads a code and a name", () => {
    expect(readAddressLookup({ code: "acme", name: "Acme Ltd" })).toEqual({
      code: "acme",
      name: "Acme Ltd",
    });
  });

  test("anything else is nobody", () => {
    expect(readAddressLookup(null)).toBeNull();
    expect(readAddressLookup("acme")).toBeNull();
    expect(readAddressLookup({ code: "acme" })).toBeNull();
    expect(readAddressLookup({ code: "Not An Address", name: "x" })).toBeNull();
    expect(readAddressLookup({ code: "acme", name: "  " })).toBeNull();
  });
});

test("displayAddress writes host and path", () => {
  expect(displayAddress("cloveerp.com", "acme")).toBe("cloveerp.com/acme");
});
