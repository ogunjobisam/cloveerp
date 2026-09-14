import { describe, expect, test } from "bun:test";
import { isValidElement } from "react";

import type { Column } from "../components/erp/auto";
import { FINANCE, RECEIVABLES_AGEING_COLUMNS, type Row } from "./modules";
import { chartBars, statementCurrency } from "./report-figures";

/**
 * Financials → Reports reads as reports.
 *
 * Receivables ageing showed a dash for every customer and every band, totals as
 * a count of pence, and a chart of one bar labelled with a dash; the trial
 * balance never loaded; the statements printed amounts with no currency. The
 * reads' own suites prove what the database answers. What can be wrong here is
 * which names the screen reads, and how an amount is shown.
 */

/** A row as public.erp_receivables_ageing answers it. */
const ageingRow: Row = {
  party_id: "p1",
  party_name: "Harbour Engineering",
  currency: "GBP",
  current_minor: 0,
  days_1_30: 2316968,
  days_31_60: 0,
  days_61_90: 0,
  days_over_90: 12500,
  total_minor: 2329468,
};

const cellText = (cell: Column<Row>["cell"], row: Row): string => {
  const shown = typeof cell === "function" ? cell(row) : row[cell];
  if (isValidElement(shown)) throw new Error("a figure is an element, not text");
  return String(shown);
};

describe("receivables ageing", () => {
  test("names the customer and shows every band as money in the row's currency", () => {
    const shown = RECEIVABLES_AGEING_COLUMNS.map((c) => [c.header, cellText(c.cell, ageingRow)]);
    expect(shown[0]).toEqual(["Customer", "Harbour Engineering"]);
    expect(shown[1]).toEqual(["Currency", "GBP"]);
    const bands = Object.fromEntries(shown.slice(2));
    expect(bands["Current"]).toContain("£0.00");
    expect(bands["1–30"]).toContain("£23,169.68");
    expect(bands["90+"]).toContain("£125.00");
    expect(bands["Total"]).toContain("£23,294.68");
    for (const value of Object.values(bands)) expect(value).not.toBe("—");
  });

  test("reads only names the read answers with", () => {
    const keys = new Set(Object.keys(ageingRow));
    const plain = RECEIVABLES_AGEING_COLUMNS.filter((c) => typeof c.cell !== "function");
    for (const c of plain) expect(keys.has(String(c.cell))).toBe(true);
    // A money cell reading a name the row does not carry prints a dash.
    const money = RECEIVABLES_AGEING_COLUMNS.filter((c) => typeof c.cell === "function");
    expect(money).toHaveLength(6);
    for (const c of money) expect(cellText(c.cell, ageingRow)).not.toBe("—");
  });

  test("the panel is the report the tab shows, and the chart labels each customer", () => {
    const panel = FINANCE.reports.find((r) => r.fn === "erp_receivables_ageing");
    expect(panel?.columns).toBe(RECEIVABLES_AGEING_COLUMNS);
    expect(FINANCE.chart?.label(ageingRow)).toBe("Harbour Engineering");
    expect(FINANCE.chart?.money?.(ageingRow)).toBe("GBP");
  });
});

describe("the trial balance", () => {
  test("asks for the general ledger and shows amounts as money", () => {
    const panel = FINANCE.reports.find((r) => r.fn === "erp_trial_balance");
    expect(panel?.args).toEqual({ p_ledger: "GL" });
    const row: Row = {
      entity: "ACME",
      ledger: "GL",
      account: "1100",
      name: "Trade receivables",
      account_type: "asset",
      currency: "GBP",
      debit_minor: 195914,
      credit_minor: 0,
      balance_minor: 195914,
    };
    const shown = Object.fromEntries(
      (panel?.columns ?? []).map((c) => [c.header, cellText(c.cell, row)]),
    );
    expect(shown["Company"]).toBe("ACME");
    expect(shown["Debit"]).toContain("£1,959.14");
    expect(shown["Balance"]).toContain("£1,959.14");
    expect(panel?.rowKey(row, 0)).toBe("ACME-GL-1100-GBP");
  });
});

describe("a money chart", () => {
  const spec = {
    label: (r: Row) => String(r["party_name"] ?? "—"),
    value: (r: Row) => Number(r["total_minor"] ?? 0),
    money: (r: Row) => String(r["currency"] ?? "GBP"),
  };

  test("draws a bar per customer, in whole units with the currency's symbol, largest first", () => {
    const bars = chartBars(
      [
        { party_name: "Vela", currency: "GBP", total_minor: 19591400 },
        { party_name: "Harbour", currency: "GBP", total_minor: 2316968 },
        { party_name: "Harbour", currency: "GBP", total_minor: 1000 },
      ],
      spec,
    );
    expect(bars.map((b) => b.label)).toEqual(["Vela", "Harbour"]);
    expect(bars[0]?.shown).toContain("£195,914");
    expect(bars[1]?.value).toBe(2317968);
    expect(bars[1]?.shown).toContain("£23,180");
  });

  test("never adds one currency to another under a label", () => {
    const bars = chartBars(
      [
        { party_name: "Lumen", currency: "GBP", total_minor: 5000 },
        { party_name: "Lumen", currency: "EUR", total_minor: 7000 },
      ],
      spec,
    );
    expect(bars).toHaveLength(2);
    expect(new Set(bars.map((b) => b.key)).size).toBe(2);
    expect(bars[0]?.shown).toContain("€");
  });

  test("uses the currency's own exponent", () => {
    const bars = chartBars(
      [{ party_name: "Osaka", currency: "JPY", total_minor: 1500 }],
      spec,
      (c) => (c === "JPY" ? 0 : 2),
    );
    expect(bars[0]?.shown).toContain("1,500");
  });

  test("a chart that is not money reads as it always did, and stops at eight bars", () => {
    const rows = Array.from({ length: 10 }, (_, i) => ({ band: `b${i}`, n: i + 0.4 }));
    const bars = chartBars(rows, {
      label: (r) => String(r["band"]),
      value: (r) => Number(r["n"]),
      unit: "%",
    });
    expect(bars).toHaveLength(8);
    expect(bars[0]?.shown).toBe("9%");
  });
});

describe("a statement's currency", () => {
  test("is the currency its lines are in", () => {
    expect(statementCurrency([{ currency: null }, { currency: "EUR" }])).toBe("EUR");
  });

  test("is the fallback when no line names one", () => {
    expect(statementCurrency([])).toBe("GBP");
    expect(statementCurrency([{ currency: " " }], "USD")).toBe("USD");
  });
});
