import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

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
      returned: 0,
      kept: 0,
      bought: 0,
      boughtPriceMinor: null,
      purpose: "shoot",
      dueBack: "2026-09-24",
      overdue: true,
      currency: "GBP",
      maySettle: true,
    });
  });

  test("reads what became of the rest: returned, kept, bought and the price each was bought at (J-15)", () => {
    const s = sample(
      row({
        held: "0.000000",
        returned: "1.000000",
        kept: "1.000000",
        bought: "1.000000",
        bought_price_minor: 9000,
      }),
    );
    expect(s?.returned).toBe(1);
    expect(s?.kept).toBe(1);
    expect(s?.bought).toBe(1);
    expect(s?.boughtPriceMinor).toBe(9000);
    expect(s?.held).toBe(0);
    expect(sample(row({ bought_price_minor: null }))?.boughtPriceMinor).toBeNull();
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

describe("samples are received from the card that lists them (J-68)", () => {
  const ROOT = join(import.meta.dir, "..");
  const card = readFileSync(join(ROOT, "components", "erp", "samples.tsx"), "utf8");
  const screen = readFileSync(join(ROOT, "routes", "procurement", "index.tsx"), "utf8");

  test("the Samples card offers Receive samples, gated as it was", () => {
    const dialog = card.slice(card.indexOf("function ReceiveSamples"));
    expect(dialog).toContain('title="Receive samples"');
    expect(dialog).toContain('permission="procurement.receive"');
    expect(dialog).toContain('fn="erp_receive_samples"');
    // Drawn in the card's header, and for whoever may receive though not read.
    expect(card).toMatch(/\{ui\("Samples"\)\}<\/h2>\s*<ReceiveSamples \/>/);
    expect(card).toContain("if (!mayRead && !mayReceive) return null;");
  });

  test("and the header's sheet no longer offers it a second time", () => {
    expect(screen).not.toContain('label: "Receive samples"');
    expect(screen).not.toContain('"erp_receive_samples"');
  });
});
