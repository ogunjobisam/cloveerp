import { describe, expect, test } from "bun:test";

import { chargeWords, landedCost, landedCosts } from "./landed-costs";

/** A row as public.erp_landed_costs answers it (20261004970000). */
const row = (over: Record<string, unknown> = {}) => ({
  landed_cost_id: "lc1",
  bill_id: "b1",
  bill: "LCB-000001",
  receipt_id: "r1",
  receipt: "GRN-000001",
  supplier: "Dover Customs Brokers",
  charge_code: "duty",
  amount_minor: 20000,
  currency: "GBP",
  capitalised_minor: 11000,
  expensed_minor: 9000,
  ...over,
});

describe("a landed cost", () => {
  test("reads its bill, receipt, supplier, charge, and what landed and what was expensed", () => {
    expect(landedCost(row())).toEqual({
      id: "lc1",
      billId: "b1",
      bill: "LCB-000001",
      receiptId: "r1",
      receipt: "GRN-000001",
      supplier: "Dover Customs Brokers",
      charge: "duty",
      amountMinor: 20000,
      currency: "GBP",
      capitalisedMinor: 11000,
      expensedMinor: 9000,
    });
  });

  test("one not yet placed has no split, and the list keeps only rows that are one", () => {
    expect(
      landedCost(row({ capitalised_minor: null, expensed_minor: null }))?.capitalisedMinor,
    ).toBeNull();
    expect(
      landedCosts([row(), { nope: 1 }, row({ landed_cost_id: "lc2" })]).map((c) => c.id),
    ).toEqual(["lc1", "lc2"]);
    expect(landedCosts(null)).toEqual([]);
  });

  test("a charge reads in the words its choice reads in", () => {
    expect(chargeWords("duty")).toBe("Duty");
    expect(chargeWords("brokerage")).toBe("Brokerage");
    expect(chargeWords("something")).toBe("Other");
  });
});
