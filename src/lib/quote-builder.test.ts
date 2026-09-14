import { describe, expect, test } from "bun:test";

import {
  contractDefaults,
  discountCeiling,
  extraItemFor,
  lineFor,
  money,
  oneOffItems,
  partyCodeFor,
  planItems,
  quotePlan,
  rateFor,
  stageOf,
  termLabel,
  userItemFor,
  type PriceItem,
  type QuoteLine,
} from "./quote-builder";

const item = (over: Partial<PriceItem> & { code: string; kind: string }): PriceItem => ({
  name: over.code,
  status: "active",
  plan_code: null,
  entitlement_code: null,
  support_severity_code: null,
  description: null,
  included_users: null,
  charge: "recurring",
  percent_of_recurring: null,
  rates: [],
  ...over,
});

const BOOK: PriceItem[] = [
  item({ code: "PLAN-ENTERPRISE", kind: "plan_tier", plan_code: "enterprise", included_users: 40 }),
  item({
    code: "PLAN-STARTER",
    kind: "plan_tier",
    plan_code: "starter",
    included_users: 5,
    rates: [
      { price_book_code: "CLOVE-LIST", term_kind: "annual", currency: "GBP", amount_minor: 474000 },
      { price_book_code: "CLOVE-LIST", term_kind: "monthly", currency: "GBP", amount_minor: 45425 },
    ],
  }),
  item({ code: "PLAN-STANDARD", kind: "plan_tier", plan_code: "standard", included_users: 15 }),
  item({ code: "USER-STANDARD", kind: "full_user", plan_code: "standard" }),
  item({ code: "LIGHT-STANDARD", kind: "light_user", plan_code: "standard" }),
  item({ code: "USER-STARTER", kind: "full_user", plan_code: "starter" }),
  item({ code: "COMPANY-EXTRA", kind: "service", entitlement_code: "companies" }),
  item({ code: "ONBOARD-GUIDED", kind: "service", charge: "one_off" }),
  item({ code: "OLD-PLAN", kind: "plan_tier", plan_code: "standard", status: "inactive" }),
];

describe("the book as choices", () => {
  test("plans in the order they are sold, active only", () => {
    expect(planItems(BOOK).map((p) => p.code)).toEqual([
      "PLAN-STARTER",
      "PLAN-STANDARD",
      "PLAN-ENTERPRISE",
    ]);
  });

  test("a rate is for a book, a term and a currency", () => {
    const starter = BOOK[1]!;
    expect(rateFor(starter, "CLOVE-LIST", "annual")).toBe(474000);
    expect(rateFor(starter, "CLOVE-LIST", "monthly")).toBe(45425);
    expect(rateFor(starter, "CLOVE-LIST", "multi_year")).toBeNull();
    expect(rateFor(starter, "OTHER", "annual")).toBeNull();
  });

  test("users are priced for the quote's own plan", () => {
    expect(userItemFor(BOOK, "full_user", "standard")?.code).toBe("USER-STANDARD");
    expect(userItemFor(BOOK, "light_user", "standard")?.code).toBe("LIGHT-STANDARD");
    expect(userItemFor(BOOK, "light_user", "starter")).toBeNull();
    expect(userItemFor(BOOK, "full_user", null)).toBeNull();
  });

  test("an extra is found by the limit it raises, and one-off items by their charge", () => {
    expect(extraItemFor(BOOK, "companies")?.code).toBe("COMPANY-EXTRA");
    expect(extraItemFor(BOOK, "sites")).toBeNull();
    expect(oneOffItems(BOOK).map((i) => i.code)).toEqual(["ONBOARD-GUIDED"]);
  });
});

describe("a quote as it stands", () => {
  const line = (over: Partial<QuoteLine> & { item_code: string }): QuoteLine => ({
    line_id: over.item_code,
    line_no: 1,
    name: over.item_code,
    kind: null,
    quantity: 1,
    list_minor: 0,
    discount_pct: 0,
    quoted_unit_minor: 0,
    quoted_minor: 0,
    margin_pct: null,
    below_cost: false,
    plan_code: null,
    entitlement_code: null,
    charge: "recurring",
    ...over,
  });

  test("the plan comes from the plan line", () => {
    const lines = [
      line({ item_code: "USER-STANDARD", kind: "full_user", plan_code: "standard" }),
      line({ item_code: "PLAN-STANDARD", kind: "plan_tier", plan_code: "standard" }),
    ];
    expect(quotePlan(lines)).toBe("standard");
    expect(quotePlan([])).toBeNull();
    expect(lineFor(lines, "USER-STANDARD")?.kind).toBe("full_user");
    expect(lineFor(lines, null)).toBeNull();
  });

  test("the pipeline stage follows the lifecycle, and a replaced version is closed", () => {
    expect(stageOf("draft", null)).toBe("draft");
    expect(stageOf("pending_approval", null)).toBe("approval");
    expect(stageOf("approved", null)).toBe("ready");
    expect(stageOf("issued", null)).toBe("sent");
    expect(stageOf("accepted", null)).toBe("won");
    expect(stageOf("declined", null)).toBe("closed");
    expect(stageOf("expired", null)).toBe("closed");
    expect(stageOf("issued", "next-version")).toBe("closed");
  });

  test("the discount ceiling is 25%, or 35% for a founding customer", () => {
    expect(discountCeiling(null)).toBe(25);
    expect(discountCeiling("founding")).toBe(35);
  });
});

describe("words and defaults", () => {
  test("a prospect's code comes from their name and never collides on a shared start", () => {
    expect(partyCodeFor("Okafor Foods Ltd", "a1b2")).toBe("OKAFOR-FOODS-LTD-A1B2");
    expect(partyCodeFor("Crème & Co.", "9z")).toBe("CREME-CO-9Z");
    expect(partyCodeFor("  ", "")).toBe("PROSPECT-0000");
    expect(partyCodeFor("A very long company name indeed", "ffff")).toBe("A-VERY-LONG-COMP-FFFF");
  });

  test("money reads as pounds, with pence only when there are some", () => {
    expect(money(109500)).toBe("£1,095");
    expect(money(45425)).toBe("£454.25");
    expect(money(null)).toBe("—");
    expect(money(10000, "EUR")).toBe("100 EUR");
  });

  test("terms read as a person says them", () => {
    expect(termLabel("annual")).toBe("Annual");
    expect(termLabel("monthly")).toBe("Month to month");
    expect(termLabel("multi_year", 36)).toBe("3 years");
  });

  test("a contract starts from the quote: its customer, its term, and CPI capped at 5%", () => {
    expect(
      contractDefaults({
        party_name: "Acme Foods Ltd",
        customer_tenant_code: "acme",
        term_kind: "monthly",
        term_months: 12,
      }),
    ).toEqual({
      customerTenantCode: "acme",
      customerLegalName: "Acme Foods Ltd",
      initialTermMonths: "12",
      billingFrequency: "monthly",
      upliftRule: { kind: "capped", index_code: "CPI", cap_pct: 5 },
    });
    expect(
      contractDefaults({
        party_name: null,
        customer_tenant_code: null,
        term_kind: "multi_year",
        term_months: 36,
      }).billingFrequency,
    ).toBe("annual");
  });
});
