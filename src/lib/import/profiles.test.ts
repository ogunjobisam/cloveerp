import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

import { accountResolver, partyKeysFrom } from "./crosswalk";
import { controlFigure, controlQuantity, partyResolver, readFile } from "./pipeline";
import { unleashedProducts } from "./profiles/unleashed-products";
import { unleashedTerm, xeroTerm } from "./profiles/party";
import { unleashedCustomers, unleashedSuppliers } from "./profiles/unleashed-parties";
import { chartKey, controlKindOf, xeroChart } from "./profiles/xero-chart";
import { unleashedStock } from "./profiles/unleashed-stock";
import { xeroAgedPayables, xeroAgedReceivables } from "./profiles/xero-aged";
import { xeroContacts } from "./profiles/xero-contacts";
import { splitAccount, xeroTrialBalance } from "./profiles/xero-trial-balance";
import type { ChartAccount, Profile, ProfileContext, ProfileResult } from "./types";

/**
 * Each profile against a fixture built from the documented export headings,
 * with the awkward cases put in on purpose. The headings are to be confirmed
 * against real exports (the Xero Demo Company (UK) and an Unleashed trial)
 * before the profiles are built on further.
 */

const fixture = (name: string) =>
  readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8");

const ctx = (
  keys: Record<string, string> = {},
  defaultLocation = "",
  more: Partial<
    Pick<
      ProfileContext,
      | "account"
      | "chartLoaded"
      | "accounts"
      | "chartChoices"
      | "partyRoles"
      | "defaultPartyRole"
      | "termsFromXero"
      | "weightUnit"
      | "reorderSite"
    >
  > = {},
): ProfileContext => ({
  partyCode: partyResolver(keys),
  account: () => null,
  chartLoaded: false,
  defaultLocation,
  accounts: [],
  chartChoices: {},
  partyRoles: {},
  defaultPartyRole: "none",
  termsFromXero: false,
  weightUnit: "kg",
  reorderSite: "",
  ...more,
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
  const row = (i: number) => r.rows[i] as Record<string, unknown>;

  test("each contact is one whole profile, keyed by its Xero name", () => {
    expect(row(0)).toMatchObject({
      source: "xero",
      legacy_key: "Bayside Club",
      code: "BAY001",
      name: "Bayside Club",
      country_code: "AU",
    });
    expect(row(1)).toMatchObject({ code: "HAMILTONSMITHLTD", name: "Hamilton Smith Ltd" });
  });

  test("the postal address is billing and carries every line, the town and the postcode", () => {
    expect(row(0)["addresses"]).toEqual([
      {
        kind: "billing",
        lines: ["148 Bay Harbour Road"],
        locality: "Ridge Heights",
        region: "Madeupville",
        postcode: "VIC 3999",
        country_code: "AU",
      },
    ]);
    expect((row(1)["addresses"] as { lines: string[] }[])[0]?.lines).toEqual([
      "Unit 4, Mill Lane",
      "Line two\r\nwith a break",
    ]);
  });

  test("a town with no first line is left out and said", () => {
    expect(row(2)["addresses"]).toBeUndefined();
    expect(
      r.findings.some((f) => f.message.startsWith("the billing address has no first line")),
    ).toBe(true);
  });

  test("the default contact carries the person, email and phone", () => {
    expect(row(0)["contact"]).toEqual({
      name: "Bob Partridge",
      email: "secretary@bayside.example",
      phone: "+61 3 5555 0123",
    });
  });

  test("a VAT number is put in HMRC's form, and a malformed one is kept and flagged", () => {
    expect(row(1)["tax_identifier"]).toBe("GB123456789");
    expect(row(2)["tax_identifier"]).toBe("GB123456789");
    expect(row(3)["tax_identifier"]).toBe("GB12345");
    expect(r.findings.some((f) => f.severity === "warning" && f.message.includes("GB12345"))).toBe(
      true,
    );
  });

  test("a doubled quote in a name survives", () => {
    expect(row(4)["name"]).toBe('Ridgeway "Old" Bank');
  });

  test("an unknown country and a missing name are refused, not staged", () => {
    expect(r.rows.map((x) => x["name"])).not.toContain("Nowhere Trading");
    expect(r.findings.some((f) => f.message === "country not recognised: Atlantis")).toBe(true);
    expect(r.findings.some((f) => f.message === "no ContactName")).toBe(true);
    expect(r.rows).toHaveLength(5);
  });

  test("with no role chosen, contacts have none and the role step is named", () => {
    expect(row(0)["roles"]).toBeUndefined();
    expect(r.parties.map((p) => p.roles.length)).toEqual([0, 0, 0, 0, 0]);
    expect(r.findings.some((f) => f.message.startsWith("5 contacts have no role yet"))).toBe(true);
  });

  test("Xero terms are read and held back while Unleashed is the source", () => {
    expect(row(0)["customer_terms"]).toBeUndefined();
    expect(
      r.findings.some((f) => f.message.startsWith("3 Xero payment terms are read and not staged")),
    ).toBe(true);
  });

  test("with a default role and terms from Xero, terms follow the roles", () => {
    const withTerms = run(
      xeroContacts,
      "xero-contacts.csv",
      ctx({}, "", {
        defaultPartyRole: "customer",
        termsFromXero: true,
        partyRoles: { PowerDirect: ["supplier"] },
      }),
    );
    const at = (i: number) => withTerms.rows[i] as Record<string, unknown>;
    expect(at(0)).toMatchObject({
      roles: ["customer"],
      customer_terms: { payment_terms_code: "EOM30" },
    });
    expect(at(1)).toMatchObject({
      roles: ["customer"],
      customer_terms: { payment_terms_code: "NET30" },
    });
    expect(at(3)).toMatchObject({
      roles: ["supplier"],
      supplier_terms: { payment_terms_code: "NET30" },
    });
    expect(at(3)["customer_terms"]).toBeUndefined();
  });

  test("the names it staged are kept for the ledgers", () => {
    expect(r.partyKeys["Hamilton Smith Ltd"]).toBe("HAMILTONSMITHLTD");
  });
});

describe("Unleashed customers and suppliers", () => {
  const xero = { "Hamilton Smith Ltd": "HAMILTONSMITHLTD" };
  const r = run(unleashedCustomers, "unleashed-customers.csv", ctx(xero));
  const row = (i: number) => r.rows[i] as Record<string, unknown>;

  test("a customer carries its role, currency, term and credit limit", () => {
    expect(row(0)).toMatchObject({
      source: "unleashed",
      legacy_key: "BAYSIDE",
      code: "BAYSIDE",
      roles: ["customer"],
      customer_terms: { currency: "AUD", payment_terms_code: "NET30", credit_limit_minor: 500000 },
    });
  });

  test("a party Xero already loaded keeps its Xero code", () => {
    expect(row(1)).toMatchObject({ legacy_key: "HAM01", code: "HAMILTONSMITHLTD" });
    expect(
      r.findings.some(
        (f) => f.message === "HAM01 is HAMILTONSMITHLTD from Xero's contacts; it keeps that code",
      ),
    ).toBe(true);
  });

  test("a term Clove has no code for maps to the nearest, and says so", () => {
    expect(row(1)["customer_terms"]).toMatchObject({ payment_terms_code: "EOM30" });
    expect(row(2)["customer_terms"]).toMatchObject({ payment_terms_code: "NET14" });
    expect(
      r.findings.some((f) => f.message === "20 days has no term of its own; NET14 is the nearest"),
    ).toBe(true);
  });

  test("both addresses, the UK's other name included", () => {
    expect(row(1)["addresses"]).toEqual([
      {
        kind: "billing",
        lines: ["Unit 4", "Mill Lane"],
        locality: "Leeds",
        postcode: "LS1 4AB",
        country_code: "GB",
      },
      {
        kind: "delivery",
        lines: ["Dock 2"],
        locality: "Leeds",
        region: "West Yorkshire",
        postcode: "LS2 2BB",
        country_code: "GB",
      },
    ]);
  });

  test("obsolete, repeated and codeless lines are not staged", () => {
    expect(r.rows.map((x) => x["legacy_key"])).toEqual(["BAYSIDE", "HAM01", "NEWCO"]);
    expect(r.findings.some((f) => f.message === "skipped: OLDCO is obsolete in Unleashed")).toBe(
      true,
    );
    expect(r.findings.some((f) => f.message.startsWith("BAYSIDE is also on line"))).toBe(true);
  });

  test("a supplier carries supplier terms and no credit limit", () => {
    const s = run(unleashedSuppliers, "unleashed-suppliers.csv");
    expect(s.rows[0]).toMatchObject({
      code: "POWER",
      roles: ["supplier"],
      supplier_terms: { currency: "GBP", payment_terms_code: "EOM" },
    });
    expect(s.rows[1]).toMatchObject({
      supplier_terms: { currency: "EUR", payment_terms_code: "PREPAID" },
    });
    expect((s.rows[0] as Record<string, unknown>)["customer_terms"]).toBeUndefined();
  });
});

describe("payment terms", () => {
  test("Xero's terms", () => {
    expect(xeroTerm("30", "DAYSAFTERBILLDATE")).toEqual({ code: "NET30", note: null });
    expect(xeroTerm("0", "DAYSAFTERBILLDATE")?.code).toBe("COD");
    expect(xeroTerm("20", "OFFOLLOWINGMONTH")?.code).toBe("EOM30");
    expect(xeroTerm("0", "DAYSAFTERBILLMONTH")).toEqual({ code: "EOM", note: null });
    expect(xeroTerm("", "")).toBeNull();
  });

  test("Unleashed's terms", () => {
    expect(unleashedTerm("Net 30")).toEqual({ code: "NET30", note: null });
    expect(unleashedTerm("End of Month")).toEqual({ code: "EOM", note: null });
    expect(unleashedTerm("Prepaid")).toEqual({ code: "PREPAID", note: null });
    expect(unleashedTerm("100 days")?.code).toBe("NET90");
    expect(unleashedTerm("whenever")).toBeNull();
  });
});

describe("Unleashed products", () => {
  const suppliers = { PowerDirect: "POWERDIRECT", POWERDIRECT: "POWERDIRECT" };
  const r = run(
    unleashedProducts,
    "unleashed-products.csv",
    ctx(suppliers, "", { reorderSite: "main" }),
  );
  const row = (i: number) => r.rows[i] as Record<string, unknown>;

  test("a product is one whole profile in its own unit", () => {
    expect(row(0)).toMatchObject({
      source: "unleashed",
      code: "FIX-M6",
      name: "M6 fixings, zinc",
      description: "M6 fixings, zinc",
      item_group: "Fixings",
      stock_uom: "EA",
      purchase_uom: "BOX",
      barcode: "5012345678900",
    });
  });

  test("weights become grams, from the unit the account uses", () => {
    expect(row(0)["gross_weight_g"]).toBe("4");
    expect(row(1)["gross_weight_g"]).toBe("5200");
    const inGrams = run(
      unleashedProducts,
      "unleashed-products.csv",
      ctx({}, "", { weightUnit: "g" }),
    );
    expect((inGrams.rows[1] as Record<string, unknown>)["gross_weight_g"]).toBe("5.2");
  });

  test("tracking comes from the flags", () => {
    expect(row(0)["is_batch_controlled"]).toBeUndefined();
    expect(row(1)["is_batch_controlled"]).toBe(true);
  });

  test("a sub-penny price loads in whole pence and says what it was", () => {
    expect(row(0)["purchase_price"]).toEqual({ amount_minor: 4 });
    expect(row(0)["sales_price"]).toEqual({ amount_minor: 9 });
    expect(row(1)["sales_price"]).toEqual({ amount_minor: 2499 });
    expect(
      r.findings.some(
        (f) =>
          f.message ===
          "purchase price 0.043 loads as £0.04 a unit: prices are per unit in whole pence",
      ),
    ).toBe(true);
  });

  test("the supplier resolves through the loaded suppliers, and levels go to the chosen warehouse", () => {
    expect(row(0)["supplier"]).toEqual({ party: "POWERDIRECT", min_order_quantity: "1000" });
    expect(row(0)["sites"]).toEqual([
      { site: "MAIN", reorder_point: "5000", order_up_to: "50000", min_order_quantity: "1000" },
    ]);
  });

  test("an obsolete product is discontinued", () => {
    expect(row(2)).toMatchObject({ code: "OLD-01", lifecycle: "discontinued" });
  });

  test("a duplicate code and a missing code are refused", () => {
    expect(r.rows).toHaveLength(3);
    expect(r.findings.some((f) => f.message.startsWith("FIX-M6 is also on line"))).toBe(true);
    expect(r.findings.some((f) => f.message === "no Product Code")).toBe(true);
  });

  test("the missing VAT class is said once, for the accountant", () => {
    expect(r.findings.filter((f) => f.message.includes("VAT class"))).toHaveLength(1);
  });

  test("an unknown supplier and levels with no warehouse are said, and the product still stages", () => {
    const bare = run(unleashedProducts, "unleashed-products.csv");
    expect((bare.rows[0] as Record<string, unknown>)["supplier"]).toBeUndefined();
    expect((bare.rows[0] as Record<string, unknown>)["sites"]).toBeUndefined();
    expect(
      bare.findings.some((f) => f.message.startsWith("supplier POWERDIRECT is not in a loaded")),
    ).toBe(true);
    expect(
      bare.findings.some((f) => f.message.startsWith("2 products have stock alert levels")),
    ).toBe(true);
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

  test("a name with no code, and no chart loaded, is refused with what to do", () => {
    expect(r.findings.map((f) => f.message)).toEqual([
      "Suspense carries no account code and no loaded chart names it; load the Xero chart first, or map it there",
    ]);
  });

  test("with the chart loaded, codes and names resolve through the crosswalk", () => {
    const account = accountResolver([
      { legacy_key: "200", legacy_name: "Sales", clove_code: "4000", resolution: "map" },
      { legacy_key: "Suspense", legacy_name: "Suspense", clove_code: "XSUS", resolution: "create" },
      {
        legacy_key: "610",
        legacy_name: "Accounts Receivable",
        clove_code: "1100",
        resolution: "control",
      },
    ]);
    const mapped = run(xeroTrialBalance, "xero-trial-balance.csv", ctx({}, "", { account }));
    expect(mapped.rows).toEqual([
      { account: "4000", credit_minor: 4800000 },
      { account: "400", debit_minor: 300000 },
      { account: "090", debit_minor: 4500000 },
      { account: "XSUS", debit_minor: 1000 },
    ]);
    expect(mapped.findings).toEqual([]);
    expect(mapped.exclusions.map((e) => e.label)).toEqual([
      "610 - Accounts Receivable",
      "630 - Inventory",
      "800 - Accounts Payable",
    ]);
  });

  test("once a chart is loaded, a code it does not name is refused, not posted to whatever shares it", () => {
    const account = accountResolver([
      { legacy_key: "200", legacy_name: "Sales", clove_code: "4000", resolution: "map" },
    ]);
    const strict = run(
      xeroTrialBalance,
      "xero-trial-balance.csv",
      ctx({}, "", { account, chartLoaded: true }),
    );
    expect(strict.rows).toEqual([{ account: "4000", credit_minor: 4800000 }]);
    expect(strict.findings.map((f) => f.line)).toEqual([8, 12, 15]);
    expect(strict.findings[0]?.message).toContain("is not in the loaded Xero chart");
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

describe("Xero chart of accounts", () => {
  const clove: ChartAccount[] = [
    { code: "200", name: "Sales", control_kind: null, is_postable: true },
    { code: "1100", name: "Trade debtors", control_kind: "receivable", is_postable: true },
    { code: "2100", name: "Trade creditors", control_kind: "payable", is_postable: true },
    { code: "1200", name: "Stock", control_kind: "inventory", is_postable: true },
    { code: "400", name: "Heading", control_kind: null, is_postable: false },
  ];
  const r = run(xeroChart, "xero-chart.csv", ctx({}, "", { accounts: clove }));
  const byKey = (key: string) => r.rows.find((x) => (x["legacy_code"] ?? x["legacy_name"]) === key);

  test("the same code in both charts is mapped, never merged", () => {
    expect(byKey("200")).toEqual({
      source: "xero",
      legacy_code: "200",
      legacy_name: "Sales",
      action: "map",
      code: "200",
    });
  });

  test("Accounts Receivable, Accounts Payable and Inventory are marked as the control accounts", () => {
    expect(byKey("610")).toMatchObject({ action: "control", code: "1100" });
    expect(byKey("800")).toMatchObject({ action: "control", code: "2100" });
    expect(byKey("630")).toMatchObject({ action: "control", code: "1200" });
  });

  test("an account Clove has no code for is created, with its type", () => {
    expect(byKey("090")).toEqual({
      source: "xero",
      legacy_code: "090",
      legacy_name: "Business Bank Account",
      action: "create",
      code: "090",
      name: "Business Bank Account",
      account_type: "asset",
    });
  });

  test("a code Clove holds as a heading is created under another code, not merged", () => {
    expect(byKey("400")).toMatchObject({
      action: "create",
      name: "Advertising",
      account_type: "expense",
    });
    expect(byKey("400")?.["code"]).not.toBe("400");
  });

  test("an account with no code is known by its name", () => {
    expect(byKey("Suspense")).toMatchObject({
      action: "create",
      code: "SUSPENSE",
      account_type: "liability",
    });
    expect(chartKey("", "Suspense")).toBe("Suspense");
  });

  test("a person's choice wins over the default", () => {
    const chosen = run(
      xeroChart,
      "xero-chart.csv",
      ctx({}, "", { accounts: clove, chartChoices: { "090": { action: "map", code: "200" } } }),
    );
    expect(chosen.rows.find((x) => x["legacy_code"] === "090")).toEqual({
      source: "xero",
      legacy_code: "090",
      legacy_name: "Business Bank Account",
      action: "map",
      code: "200",
    });
  });

  test("an unknown type cannot be created, and a repeated account is refused", () => {
    expect(r.findings.map((f) => f.message)).toContain(
      "Mystery is not a Xero account type Clove can create; map this account instead",
    );
    expect(r.findings.some((f) => f.message.startsWith("200 is also on line"))).toBe(true);
  });

  test("a control account with no Clove control account to mark is refused until one is chosen", () => {
    const bare = run(xeroChart, "xero-chart.csv", ctx({}, "", { accounts: [] }));
    expect(
      bare.findings.some((f) =>
        f.message.startsWith("610 Accounts Receivable: choose a Clove account"),
      ),
    ).toBe(true);
  });

  test("control kinds from the name or the Xero type", () => {
    expect(controlKindOf("Accounts Receivable", "Current Asset")).toBe("receivable");
    expect(controlKindOf("Finished goods", "Inventory")).toBe("inventory");
    expect(controlKindOf("Sales", "Revenue")).toBeNull();
  });
});

describe("the crosswalk", () => {
  test("party names resolve to the codes their loaded batch gave them", () => {
    const keys = partyKeysFrom([
      {
        legacy_key: "Bayside Club",
        legacy_name: "Bayside Club",
        clove_code: "BAY001",
        resolution: "map",
      },
    ]);
    expect(partyResolver(keys)("bayside club ")).toEqual({ code: "BAY001", known: true });
  });

  test("an account resolves by code first, then by name", () => {
    const account = accountResolver([
      { legacy_key: "200", legacy_name: "Sales", clove_code: "4000", resolution: "map" },
    ]);
    expect(account("200", "Anything")).toEqual({ code: "4000", control: false });
    expect(account(null, "sales")).toEqual({ code: "4000", control: false });
    expect(account("999", "Nothing")).toBeNull();
  });
});
