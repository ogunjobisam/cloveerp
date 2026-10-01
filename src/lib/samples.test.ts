import { describe, expect, test } from "bun:test";

import { canSettle, quantityWords, sample } from "./samples";

/** A row as public.erp_samples answers it (20261004930000). */
const row = (over: Record<string, unknown> = {}) => ({
  line_id: "l1",
  receipt_id: "r1",
  receipt_number: "GRN-000001",
  received_on: "2026-10-01",
  supplier_id: "s1",
  supplier: "Maison Brand",
  item_id: "i1",
  item_code: "DRESS-NAVY-M",
  description: "Wool dress, navy, medium",
  received: "3.000000",
  held: "2.000000",
  purpose: "shoot",
  due_back: "2026-09-24",
  overdue: true,
  their_reference: "BRAND-SS27-01",
  location_code: "GOODS-IN",
  site_id: "site1",
  currency: "GBP",
  may_settle: true,
  ...over,
});

describe("a supplier's sample", () => {
  test("reads what arrived, what is still held, what for, when it is due back, and whether it is overdue", () => {
    expect(sample(row())).toEqual({
      lineId: "l1",
      receiptId: "r1",
      receiptNumber: "GRN-000001",
      supplier: "Maison Brand",
      itemCode: "DRESS-NAVY-M",
      description: "Wool dress, navy, medium",
      received: 3,
      held: 2,
      purpose: "shoot",
      dueBack: "2026-09-24",
      overdue: true,
      currency: "GBP",
      maySettle: true,
    });
  });

  test("offers Settle only where the reader may and something is still held", () => {
    expect(canSettle(sample(row()))).toBe(true);
    expect(canSettle(sample(row({ may_settle: false })))).toBe(false);
    expect(canSettle(sample(row({ held: 0 })))).toBe(false);
    expect(canSettle(null)).toBe(false);
  });

  test("a purpose the product does not know is read as none, and a row without its line is nothing", () => {
    expect(sample(row({ purpose: "party" }))?.purpose).toBeNull();
    expect(sample(row({ line_id: null }))).toBeNull();
    expect(sample(row({ held: "" }))).toBeNull();
    expect(sample("GRN-000001")).toBeNull();
  });

  test("quantities read as people write them", () => {
    expect(quantityWords(3)).toBe("3");
    expect(quantityWords(2.5)).toBe("2.5");
    expect(quantityWords(1 / 3)).toBe("0.3333");
  });
});
