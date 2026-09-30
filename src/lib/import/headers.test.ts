import { describe, expect, test } from "bun:test";

import { parseCsv } from "./csv";
import {
  autoMap,
  findHeaderRow,
  missingRequired,
  normaliseHeading,
  toSaved,
  unusedHeadings,
} from "./headers";
import { xeroContacts } from "./profiles/xero-contacts";
import { xeroTrialBalance } from "./profiles/xero-trial-balance";
import type { Column } from "./types";

const columns: Column[] = [
  { key: "name", label: "ContactName", aliases: ["Contact Name"], required: true },
  { key: "code", label: "AccountNumber", aliases: [], required: false },
  { key: "email", label: "EmailAddress", aliases: ["Email"], required: false },
];

describe("headings match however the export spelt them", () => {
  test("Xero's required-column asterisk, case, spaces and punctuation are ignored", () => {
    expect(normaliseHeading("*ContactName")).toBe("contactname");
    expect(normaliseHeading("Contact_Name ")).toBe("contactname");
  });

  test("columns map to the heading that names them", () => {
    const mapping = autoMap(["Email", "*ContactName", "Other"], columns);
    expect(mapping).toEqual({ name: 1, code: null, email: 0 });
    expect(missingRequired(mapping, columns)).toEqual([]);
    expect(unusedHeadings(mapping, ["Email", "*ContactName", "Other"])).toEqual(["Other"]);
  });

  test("a required column with no heading is reported", () => {
    const mapping = autoMap(["Email"], columns);
    expect(missingRequired(mapping, columns).map((c) => c.key)).toEqual(["name"]);
  });

  test("a remembered choice wins over the guess", () => {
    const headings = ["Customer", "Contact Name"];
    const mapping = autoMap(headings, columns, { name: "Customer" });
    expect(mapping["name"]).toBe(0);
    expect(toSaved(mapping, headings)).toEqual({ name: "Customer" });
  });

  test("a remembered heading that is no longer in the file falls back to the guess", () => {
    expect(autoMap(["Contact Name"], columns, { name: "Customer" })["name"]).toBe(0);
  });

  test("one heading is never read by two columns", () => {
    const twin: Column[] = [
      { key: "a", label: "Total", aliases: [], required: false },
      { key: "b", label: "Total", aliases: [], required: false },
    ];
    expect(autoMap(["Total"], twin)).toEqual({ a: 0, b: null });
  });
});

describe("a report's headings are found below its title lines", () => {
  test("the trial balance headings are the fourth line", () => {
    const records = parseCsv(
      "Trial Balance\nDemo\nAs at 30 September 2026\nAccount,Debit,Credit,YTD Debit,YTD Credit\n",
    ).records;
    expect(findHeaderRow(records, xeroTrialBalance)).toBe(3);
  });

  test("an export whose first line is its headings is read from the first line", () => {
    const records = parseCsv("Note,x\n*ContactName,AccountNumber\n").records;
    expect(findHeaderRow(records, xeroContacts)).toBe(0);
  });
});
