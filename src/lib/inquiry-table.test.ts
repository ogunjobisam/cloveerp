import { describe, expect, test } from "bun:test";

import {
  asTable,
  cellKind,
  currencyOf,
  fieldHeading,
  isEmptyAnswer,
  isIdentifier,
  shownEntries,
} from "./inquiry-table";

/**
 * An inquiry's answer reads as words (J-109, J-92, J-105): no identifiers, a
 * list of rows as a table, dates and money as such.
 */

const UUID = "35fb7192-e7f4-4260-a131-677cdd33c57f";

describe("an answer shows no identifiers", () => {
  test("a key ending in _id that holds a UUID, or nothing, is an identifier", () => {
    expect(isIdentifier("party_id", UUID)).toBe(true);
    expect(isIdentifier("item_supplier_id", UUID.toUpperCase())).toBe(true);
    expect(isIdentifier("site_id", null)).toBe(true);
  });

  test("words under an _id key, and a UUID under any other key, are shown", () => {
    expect(isIdentifier("vat_id", "GB123456789")).toBe(false);
    expect(isIdentifier("supplier", UUID)).toBe(false);
    expect(isIdentifier("paid", true)).toBe(false);
  });

  test("who it would be bought from shows the supplier and site, not their identifiers", () => {
    const answer = {
      item_supplier_id: UUID,
      party_id: UUID,
      supplier: "Midland Steel",
      site: "MAIN-WH",
      scope: "site",
      approved_for_use: true,
      supplier_qualified: false,
    };
    expect(shownEntries(answer).map(([k]) => k)).toEqual([
      "supplier",
      "site",
      "scope",
      "approved_for_use",
      "supplier_qualified",
    ]);
  });
});

describe("a field reads as what it is", () => {
  test("headings drop the minor-units suffix and the underscores", () => {
    expect(fieldHeading("total_minor")).toBe("total");
    expect(fieldHeading("bucket_start")).toBe("bucket start");
    expect(fieldHeading("below_reorder")).toBe("below reorder");
  });

  test("an amount in minor units is money, a date is a date, the rest is itself", () => {
    expect(cellKind("remaining_minor", 1850)).toBe("money");
    expect(cellKind("remaining_minor", null)).toBe("value");
    expect(cellKind("bucket_start", "2026-10-05")).toBe("date");
    expect(cellKind("posted_at", "2026-10-05T09:30:00.123+00:00")).toBe("date");
    expect(cellKind("posted_at", "2026-10-05 09:30:00+00")).toBe("date");
    expect(cellKind("journal_number", "JNL-000123")).toBe("value");
    expect(cellKind("closing", 12)).toBe("value");
  });

  test("money is in the record's own currency, pounds where it names none", () => {
    expect(currencyOf({ currency: "EUR" })).toBe("EUR");
    expect(currencyOf({})).toBe("GBP");
  });
});

describe("a list of rows that share their fields is a table", () => {
  const projection = [
    {
      bucket_start: "2026-10-05",
      opening: 0,
      supply: 5,
      demand: 7,
      closing: -2,
      below_reorder: true,
    },
    {
      bucket_start: "2026-10-12",
      opening: -2,
      supply: 0,
      demand: 4,
      closing: -6,
      below_reorder: true,
    },
  ];

  test("supply and demand is a table, a column per field in the order answered", () => {
    const t = asTable(projection);
    expect(t?.columns.map((c) => c.heading)).toEqual([
      "bucket start",
      "opening",
      "supply",
      "demand",
      "closing",
      "below reorder",
    ]);
    expect(t?.rows.length).toBe(2);
  });

  test("a column of identifiers is left out of the table", () => {
    const eliminations = [
      { journal_id: UUID, journal_number: "JNL-1", as_at: "2026-09-30", total_minor: 100 },
      { journal_id: UUID, journal_number: "JNL-2", as_at: "2026-08-31", total_minor: 200 },
    ];
    expect(asTable(eliminations)?.columns.map((c) => c.key)).toEqual([
      "journal_number",
      "as_at",
      "total_minor",
    ]);
  });

  test("rows that differ, rows that nest, and anything not a list are not a table", () => {
    expect(asTable([{ a: 1 }, { b: 2 }])).toBeNull();
    expect(asTable([{ a: 1 }, { a: 1, b: 2 }])).toBeNull();
    expect(asTable([{ a: 1, lines: [1, 2] }])).toBeNull();
    expect(asTable([{ a: { b: 1 } }])).toBeNull();
    expect(asTable([1, 2, 3])).toBeNull();
    expect(asTable(["a"])).toBeNull();
    expect(asTable([])).toBeNull();
    expect(asTable({ a: 1 })).toBeNull();
    expect(asTable([{ only_id: UUID }])).toBeNull();
  });
});

describe("an empty answer is recognised", () => {
  test("an empty list or no answer is empty; a record or a row is not", () => {
    expect(isEmptyAnswer([])).toBe(true);
    expect(isEmptyAnswer(null)).toBe(true);
    expect(isEmptyAnswer(undefined)).toBe(true);
    expect(isEmptyAnswer([{ a: 1 }])).toBe(false);
    expect(isEmptyAnswer({})).toBe(false);
    expect(isEmptyAnswer(0)).toBe(false);
  });
});
