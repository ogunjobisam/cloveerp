import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

import { controlFigure, controlQuantity, partyResolver, readFile } from "./pipeline";
import { unleashedProducts } from "./profiles/unleashed-products";
import { unleashedStock } from "./profiles/unleashed-stock";
import { xeroAgedPayables, xeroAgedReceivables } from "./profiles/xero-aged";
import { xeroContacts } from "./profiles/xero-contacts";
import { splitAccount, xeroTrialBalance } from "./profiles/xero-trial-balance";
import type { Profile, ProfileContext, ProfileResult } from "./types";

/**
 * Each profile against a fixture built from the documented export headings,
 * with the awkward cases put in on purpose. The headings are to be confirmed
 * against real exports (the Xero Demo Company (UK) and an Unleashed trial)
 * before the profiles are built on further.
 */

const fixture = (name: string) =>
  readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8");

const ctx = (keys: Record<string, string> = {}, defaultLocation = ""): ProfileContext => ({
  partyCode: partyResolver(keys),
  defaultLocation,
});

function run(profile: Profile, file: string, context = ctx()): ProfileResult {
  const read = readFile(fixture(file), profile, context);
  expect(read.missing).toEqual([]);
  if (!read.result) throw new Error("no result");
  return read.result;
}

const messagesAt = (r: ProfileResult, line: number) =>
  r.findings.filter((f) => f.line === line).map((f) => `${f.severity}: ${f.message}`);

describe("Xero contacts", () => {
  const r = run(xeroContacts, "xero-contacts.csv");

  test("an AccountNumber is the code; a blank one is derived from the name", () => {
    expect(r.rows[0]).toMatchObject({ code: "BAY001", name: "Bayside Club", country_code: "AU" });
    expect(r.rows[1]).toMatchObject({ code: "HAMILTONSMITHLTD", name: "Hamilton Smith Ltd" });
  });

  test("a VAT number is put in HMRC's form, and a bare nine digits gains its GB", () => {
    expect(r.rows[1]?.["tax_identifier"]).toBe("GB123456789");
    expect(r.rows[2]?.["tax_identifier"]).toBe("GB123456789");
  });

  test("a malformed VAT number is kept and flagged", () => {
    expect(r.rows[3]?.["tax_identifier"]).toBe("GB12345");
    expect(r.findings.some((f) => f.severity === "warning" && f.message.includes("GB12345"))).toBe(
      true,
    );
  });

  test("the UK's other names are GB", () => {
    expect(r.rows[1]?.["country_code"]).toBe("GB");
    expect(r.rows[2]?.["country_code"]).toBe("GB");
    expect(r.rows[3]?.["country_code"]).toBe("GB");
  });

  test("a doubled quote in a name survives", () => {
    expect(r.rows[4]?.["name"]).toBe('Ridgeway "Old" Bank');
  });

  test("an unknown country and a missing name are refused, not staged", () => {
    expect(r.rows.map((x) => x["name"])).not.toContain("Nowhere Trading");
    expect(r.findings.some((f) => f.message === "country not recognised: Atlantis")).toBe(true);
    expect(r.findings.some((f) => f.message === "no ContactName")).toBe(true);
    expect(r.rows).toHaveLength(5);
  });

  test("only keys the party door accepts are staged", () => {
    const allowed = new Set([
      "code",
      "name",
      "legal_name",
      "tax_identifier",
      "registration_number",
      "country_code",
    ]);
    for (const row of r.rows) for (const k of Object.keys(row)) expect(allowed.has(k)).toBe(true);
  });

  test("addresses, contacts and terms are reported as waiting, not dropped", () => {
    expect(r.deferred.some((d) => d.startsWith("POAddressLine1"))).toBe(true);
    expect(r.deferred.some((d) => d.startsWith("DueDateSalesTerm"))).toBe(true);
    expect(r.deferred.some((d) => d.startsWith("EmailAddress"))).toBe(true);
  });

  test("the names it staged are kept for the ledgers", () => {
    expect(r.partyKeys["Hamilton Smith Ltd"]).toBe("HAMILTONSMITHLTD");
  });
});

describe("Unleashed products", () => {
  const r = run(unleashedProducts, "unleashed-products.csv");

  test("code, name, description and group", () => {
    expect(r.rows[0]).toEqual({
      code: "FIX-M6",
      name: "M6 fixings, zinc",
      description: "M6 fixings, zinc",
      item_group: "Fixings",
    });
  });

  test("an obsolete product is discontinued", () => {
    expect(r.rows[2]).toMatchObject({ code: "OLD-01", lifecycle: "discontinued" });
  });

  test("a duplicate code and a missing code are refused", () => {
    expect(r.rows).toHaveLength(3);
    expect(r.findings.some((f) => f.message.startsWith("FIX-M6 is also on line"))).toBe(true);
    expect(r.findings.some((f) => f.message === "no Product Code")).toBe(true);
  });

  test("the missing VAT class is said once, for the accountant", () => {
    expect(r.findings.filter((f) => f.message.includes("VAT class"))).toHaveLength(1);
  });

  test("units, tracking, prices and supply wait for the item extras", () => {
    for (const name of [
      "Unit Of Measure",
      "Is Batch Tracked",
      "Barcode",
      "Default Sell Price",
      "Supplier",
    ]) {
      expect(r.deferred.some((d) => d.startsWith(name))).toBe(true);
    }
  });
});

describe("Unleashed stock on hand", () => {
  const r = run(unleashedStock, "unleashed-stock.csv", ctx({}, "MAIN-DEFAULT"));

  test("the heading row is found below the report's title", () => {
    expect(r.lines[0]).toBe(4);
  });

  test("rows in the stock door's shape", () => {
    expect(r.rows[0]).toEqual({
      item: "FIX-M6",
      site: "MAIN",
      location: "A-01",
      quantity: "50000",
      unit_cost_minor: 4,
    });
    expect(r.rows[1]).toEqual({
      item: "PAINT-5L",
      site: "MAIN",
      location: "MAIN-DEFAULT",
      quantity: "40",
      unit_cost_minor: 1150,
      batch: "B123",
      expires_on: "2027-03-31",
    });
  });

  test("a sub-penny average cost says what it will load at and what Unleashed says", () => {
    expect(messagesAt(r, 4)).toEqual([
      "warning: loads at £2,000.00 (£0.04 a unit); Unleashed says £2,150.00. The exact value arrives with M5",
    ]);
  });

  test("zero and negative lines are held back with their value", () => {
    expect(r.exclusions.map((e) => [e.label, e.quantity, e.amountMinor])).toEqual([
      ["OLD-01 at MAIN", "0", 0],
      ["WID-02 at NORTH", "-3", -600],
    ]);
  });

  test("the totals the loader will reach", () => {
    expect(r.stagedTotalMinor).toBe(200000 + 46000);
    expect(r.stagedQuantity).toBe("50040");
  });

  test("printed less exclusions is the control, and the gap left is the M5 gap", () => {
    expect(controlFigure(260400, r.exclusions)).toBe(261000);
    expect(controlQuantity("50037", r.exclusions)).toBe("50040");
  });

  test("with no bin and no default location, the line is refused", () => {
    const bare = run(unleashedStock, "unleashed-stock.csv");
    expect(bare.rows.map((x) => x["item"])).toEqual(["FIX-M6"]);
    expect(messagesAt(bare, 5)[0]).toContain("no default location");
  });
});

describe("Xero aged receivables", () => {
  const keys = { "Bayside Club": "BAY001", "Hamilton Smith Ltd": "HAMILTONSMITHLTD" };
  const r = run(xeroAgedReceivables, "xero-aged-receivables.csv", ctx(keys));

  test("lines take the contact from their group heading", () => {
    expect(r.rows).toEqual([
      {
        party: "BAY001",
        reference: "INV-0101",
        amount_minor: 123450,
        document_date: "2026-09-03",
        due_date: "2026-10-03",
      },
      {
        party: "BAY001",
        reference: "CN-0007",
        amount_minor: -12000,
        document_date: "2026-08-15",
        due_date: "2026-08-15",
      },
      {
        party: "HAMILTONSMITHLTD",
        reference: "INV-0088",
        amount_minor: 200000,
        document_date: "2026-07-01",
        due_date: "2026-07-31",
      },
    ]);
  });

  test("a foreign-currency line is held back with its amount", () => {
    expect(r.exclusions).toEqual([
      {
        line: 11,
        label: "Hamilton Smith Ltd INV-0110",
        reason: "in EUR; foreign-currency items load in v1.1",
        amountMinor: 50000,
        quantity: null,
      },
    ]);
  });

  test("nothing outstanding is skipped and said", () => {
    expect(messagesAt(r, 12)).toEqual(["info: skipped: INV-0111 has nothing outstanding"]);
  });

  test("an impossible date and a third decimal place are refused", () => {
    expect(messagesAt(r, 15)).toEqual(["error: invoice date is not a date: 31/02/2026"]);
    expect(messagesAt(r, 16)).toEqual(["error: amount has more than two decimal places: 10.005"]);
  });

  test("the staged total, and the control it should meet", () => {
    expect(r.stagedTotalMinor).toBe(123450 - 12000 + 200000);
    // The printed total counts the refused lines too: the screen shows the gap.
    expect(controlFigure(371449, r.exclusions)).toBe(321449);
  });

  test("a contact no contacts file named is derived and warned", () => {
    const bare = run(xeroAgedReceivables, "xero-aged-receivables.csv");
    expect(bare.rows[0]?.["party"]).toBe("BAYSIDECLUB");
    expect(messagesAt(bare, 6)[0]).toContain("not in a contacts file");
  });

  test("payables read the same file shape into the purchase ledger", () => {
    expect(xeroAgedPayables.target).toEqual({ kind: "opening", domain: "purchase_ledger" });
    expect(xeroAgedPayables.columns).toBe(xeroAgedReceivables.columns);
  });
});

describe("Xero trial balance", () => {
  const r = run(xeroTrialBalance, "xero-trial-balance.csv");

  test("the account code is read from either form", () => {
    expect(splitAccount("200 - Sales")).toEqual({ code: "200", name: "Sales" });
    expect(splitAccount("Advertising (400)")).toEqual({ code: "400", name: "Advertising" });
    expect(splitAccount("Suspense")).toEqual({ code: null, name: "Suspense" });
    expect(splitAccount("Rent - Office")).toEqual({ code: null, name: "Rent - Office" });
  });

  test("year-to-date columns, not the period ones", () => {
    expect(r.rows).toEqual([
      { account: "200", credit_minor: 4800000 },
      { account: "400", debit_minor: 300000 },
      { account: "090", debit_minor: 4500000 },
    ]);
  });

  test("the three control accounts are held back, each with its Xero figure", () => {
    expect(r.exclusions.map((e) => [e.label, e.amountMinor])).toEqual([
      ["610 - Accounts Receivable", 371449],
      ["630 - Inventory", 260400],
      ["800 - Accounts Payable", 0],
    ]);
    expect(r.exclusions[0]?.reason).toBe(
      "control account, explained by the sales ledger; Xero shows debit £3,714.49, credit £0.00",
    );
  });

  test("a name with no code waits for the chart mapping", () => {
    expect(r.findings.map((f) => f.message)).toEqual([
      "Suspense carries no account code; map it to a Clove account (chart mapping arrives in PR 2)",
    ]);
  });

  test("debits staged against the printed debits less the control accounts", () => {
    expect(r.stagedTotalMinor).toBe(4800000);
    expect(controlFigure(5432849, r.exclusions)).toBe(4801000);
  });
});

describe("a file that cannot be read says why", () => {
  test("a required column with no heading stops the transform", () => {
    const read = readFile("Code,Name\nA,B\n", xeroTrialBalance, ctx());
    expect(read.result).toBeNull();
    expect(read.missing.map((c) => c.key)).toEqual(["account", "ytd_debit", "ytd_credit"]);
  });

  test("an unclosed quote stops it too", () => {
    const read = readFile('*ContactName\n"Never closed\n', xeroContacts, ctx());
    expect(read.result).toBeNull();
    expect(read.findings[0]?.severity).toBe("error");
  });
});
