import { describe, expect, test } from "bun:test";

import { CONSOLE_SECTIONS } from "./platform-console";
import {
  assuranceCards,
  enquiryCards,
  healthSummary,
  incidentCards,
  invoiceCards,
  listNames,
  organisationCards,
  paymentDetailsCards,
  priceListLoaded,
  revenueCards,
  sellingCards,
  summariseToday,
  supportWindowCards,
  transferCards,
  type OpenInvoiceRow,
  type RevenueRead,
  type TodayCard,
} from "./platform-today";

const NOW = new Date("2026-09-14T12:00:00Z");
const hoursAgo = (h: number) => new Date(NOW.getTime() - h * 3600_000).toISOString();

const QUIET_REVENUE: RevenueRead = {
  renewals: [],
  revenue_at_risk: [],
  revenue_at_risk_minor: 0,
  invoices: { issued_minor: 0 },
  gross_margin: [],
};

/** A card's button must open a tab that exists. */
function opensARealTab(card: TodayCard) {
  const section = CONSOLE_SECTIONS.find((s) => s.key === card.target.section);
  expect(section).toBeDefined();
  expect(section!.views.some((v) => v.key === card.target.view)).toBe(true);
}

describe("failing checks", () => {
  test("say which, and open Diagnostics", () => {
    const cards = assuranceCards([
      { code: "a", title: "Tenant isolation", ok: false },
      { code: "b", ok: true },
      { code: "c", ok: null },
    ]);
    expect(cards).toHaveLength(1);
    expect(cards[0]!.figure).toBe("1");
    expect(cards[0]!.sentence).toContain("Tenant isolation");
    expect(cards[0]!.target).toEqual({ section: "platform", view: "diagnostics" });
    opensARealTab(cards[0]!);
  });

  test("a check that needs an organisation to run is not failing", () => {
    expect(assuranceCards([{ code: "c", ok: null }])).toEqual([]);
    expect(
      healthSummary([
        { code: "c", ok: null },
        { code: "d", ok: true },
      ]),
    ).toEqual({
      passing: 1,
      failing: 0,
      needOrganisation: 1,
    });
  });
});

describe("enquiries", () => {
  test("new means asked in the last seven days, and an erased one is gone", () => {
    const cards = enquiryCards(
      [
        { submitted_at: hoursAgo(2), status: "notified" },
        { submitted_at: hoursAgo(24 * 6), status: "notified" },
        { submitted_at: hoursAgo(24 * 8), status: "notified" },
        { submitted_at: hoursAgo(1), status: "erased" },
      ],
      NOW,
    );
    expect(cards.map((c) => c.key)).toEqual(["enquiries"]);
    expect(cards[0]!.figure).toBe("2");
    opensARealTab(cards[0]!);
  });

  test("one that was never emailed is its own card, whatever its age", () => {
    const cards = enquiryCards(
      [
        { submitted_at: hoursAgo(24 * 30), status: "notification_failed" },
        { submitted_at: hoursAgo(1), status: "new" },
        { submitted_at: new Date(NOW.getTime() - 5 * 60_000).toISOString(), status: "new" },
      ],
      NOW,
    );
    const undelivered = cards.find((c) => c.key === "enquiries-undelivered");
    // The five-minute-old one is still being sent; the hour-old one stopped.
    expect(undelivered?.figure).toBe("2");
    expect(undelivered?.tone).toBe("bad");
  });

  test("nothing asked, nothing shown", () => {
    expect(enquiryCards([], NOW)).toEqual([]);
  });

  test("an enquiry somebody marked handled needs nobody, even one that was never emailed", () => {
    const cards = enquiryCards(
      [
        {
          submitted_at: hoursAgo(24 * 10),
          status: "notification_failed",
          handled_at: hoursAgo(1),
        },
        { submitted_at: hoursAgo(2), status: "notified", handled_at: hoursAgo(1) },
      ],
      NOW,
    );
    expect(cards).toEqual([]);
  });
});

describe("renewals and invoices", () => {
  test("a quiet register raises nothing", () => {
    expect(revenueCards(QUIET_REVENUE)).toEqual([]);
  });

  test("renewals to decide and contracts at risk each have a card", () => {
    const cards = revenueCards({
      renewals: [
        { status: "proposed", tenant_code: "acme" },
        { status: "quoted", tenant_code: "bolt" },
        { status: "accepted", tenant_code: "core" },
      ],
      revenue_at_risk: [{ tenant_code: "acme", annual_value_minor: 2_400_000 }],
      revenue_at_risk_minor: 2_400_000,
      invoices: { issued_minor: 120_000 },
      gross_margin: [{ currency: "GBP" }],
    });
    // Unpaid invoices are not a revenue card any more: an invoice not yet due
    // needs nobody, and one that is late has a card of its own.
    expect(cards.map((c) => c.key)).toEqual(["renewals", "at-risk"]);
    expect(cards[0]!.figure).toBe("2");
    expect(cards[0]!.sentence).toContain("acme and bolt");
    expect(cards[1]!.tone).toBe("bad");
    for (const c of cards) opensARealTab(c);
  });

  const invoice = (over: Partial<OpenInvoiceRow>): OpenInvoiceRow => ({
    reference: "INV-1",
    tenant_code: "acme",
    customer_legal_name: "Acme Ltd",
    currency: "GBP",
    total_minor: 39_500,
    due_on: "2026-09-01",
    overdue: false,
    days_overdue: 0,
    ...over,
  });

  test("an invoice not yet due needs nobody", () => {
    expect(invoiceCards([invoice({})])).toEqual([]);
  });

  test("late invoices say how much, from whom and how late, and one customer opens its page", () => {
    const one = invoiceCards([
      invoice({ reference: "INV-1", overdue: true, days_overdue: 13 }),
      invoice({ reference: "INV-2", overdue: true, days_overdue: 1, total_minor: 20_500 }),
      invoice({ reference: "INV-3" }),
    ]);
    expect(one).toHaveLength(1);
    expect(one[0]!.figure).toBe("2");
    expect(one[0]!.tone).toBe("bad");
    expect(one[0]!.sentence).toMatch(
      /600 from Acme Ltd are past the due date; the oldest is 13 days late\.$/,
    );
    expect(one[0]!.target).toEqual({ section: "customers", view: "organisations", org: "acme" });
    opensARealTab(one[0]!);

    const two = invoiceCards([
      invoice({ overdue: true, days_overdue: 1 }),
      invoice({
        tenant_code: "bolt",
        customer_legal_name: "Bolt plc",
        currency: "EUR",
        overdue: true,
        days_overdue: 1,
      }),
    ]);
    expect(two[0]!.sentence).toBe(
      "2 invoices from Acme Ltd and Bolt plc are past the due date; the oldest is 1 day late.",
    );
    expect(two[0]!.target).toEqual({ section: "sales", view: "contracts" });
    opensARealTab(two[0]!);
  });
});

describe("support windows", () => {
  const inHours = (h: number) => new Date(NOW.getTime() + h * 3600_000).toISOString();

  test("an open window says who is inside, where, and for how long", () => {
    const cards = supportWindowCards(
      [
        {
          tenant_code: "acme",
          tenant_name: "Acme",
          staff_email: "sam@clove.test",
          is_write_access: true,
          expires_at: inHours(0.5),
        },
        {
          tenant_code: "bolt",
          tenant_name: "Bolt",
          staff_email: "sam@clove.test",
          is_write_access: false,
          expires_at: hoursAgo(1),
        },
      ],
      NOW,
    );
    expect(cards).toHaveLength(1);
    expect(cards[0]!.sentence).toBe(
      "sam@clove.test is inside Acme with write access; the window closes in 30 minutes.",
    );
    expect(cards[0]!.target).toEqual({ section: "customers", view: "organisations", org: "acme" });
    opensARealTab(cards[0]!);
  });

  test("several windows name the organisations and the last to close", () => {
    const cards = supportWindowCards(
      [
        {
          tenant_code: "a",
          tenant_name: "A",
          staff_email: "x@t",
          is_write_access: false,
          expires_at: inHours(4),
        },
        {
          tenant_code: "b",
          tenant_name: "B",
          staff_email: "y@t",
          is_write_access: false,
          expires_at: inHours(1),
        },
      ],
      NOW,
    );
    expect(cards[0]!.figure).toBe("2");
    expect(cards[0]!.sentence).toBe(
      "Platform staff are inside B and A; the last window closes in 4 hours.",
    );
    expect(supportWindowCards([], NOW)).toEqual([]);
  });
});

describe("payment details", () => {
  test("asks for them before an invoice goes out without them, and opens where they are set", () => {
    const cards = paymentDetailsCards({ set: false });
    expect(cards).toHaveLength(1);
    expect(cards[0]!.title).toBe("Add payment details before invoices go out");
    expect(cards[0]!.tone).toBe("warn");
    expect(cards[0]!.action).toBe("Add payment details");
    expect(cards[0]!.target).toEqual({ section: "billing", view: "payment" });
    opensARealTab(cards[0]!);
  });

  test("says nothing once they are set", () => {
    expect(
      paymentDetailsCards({
        set: true,
        legal_name: "Example Supplier Ltd",
        bank_account_name: "Example Supplier Ltd",
        sort_code: "00-00-00",
        account_number: "00000000",
      }),
    ).toEqual([]);
  });
});

describe("incidents", () => {
  test("only unresolved ones, and says when an update is late", () => {
    const cards = incidentCards([
      { code: "INC-1", title: "Slow sign-in", state: "declared", overdue: true },
      { code: "INC-0", title: "Old", state: "resolved", overdue: false },
    ]);
    expect(cards[0]!.figure).toBe("1");
    expect(cards[0]!.sentence).toBe(
      "Slow sign-in (INC-1) is still open and its next update is overdue.",
    );
    opensARealTab(cards[0]!);
    expect(
      incidentCards([{ code: "INC-0", title: "Old", state: "resolved", overdue: false }]),
    ).toEqual([]);
  });
});

describe("ownership transfers", () => {
  test("pending offers, and whether one is yours to answer", () => {
    const cards = transferCards([
      { status: "pending", is_mine_to_answer: true },
      { status: "pending", is_mine_to_answer: false },
      { status: "declined", is_mine_to_answer: true },
    ]);
    expect(cards[0]!.figure).toBe("2");
    expect(cards[0]!.sentence).toContain("offered to you");
    expect(cards[0]!.target).toEqual({ section: "customers", view: "ownership" });
    expect(transferCards([{ status: "accepted", is_mine_to_answer: false }])).toEqual([]);
  });
});

describe("selling", () => {
  test("no platform organisation is two steps", () => {
    const cards = sellingCards({ platform_organisation: null, price_items: 0, selling: null });
    expect(cards[0]!.figure).toBe("2");
    expect(cards[0]!.target).toEqual({ section: "catalogue", view: "selling" });
    opensARealTab(cards[0]!);
  });

  test("an organisation with no price list is one", () => {
    const cards = sellingCards({
      platform_organisation: { tenant_code: "clove", name: "Clove ERP Ltd" },
      price_items: 0,
      selling: { installed: true, price_book: null, waiting: false },
    });
    expect(cards[0]!.figure).toBe("1");
    expect(cards[0]!.sentence).toContain("Clove ERP Ltd");
  });

  test("a loaded price list is nothing to do", () => {
    const state = {
      platform_organisation: { tenant_code: "clove", name: null },
      price_items: 40,
      selling: { installed: true, price_book: { code: "LIST" }, waiting: false },
    };
    expect(priceListLoaded(state)).toBe(true);
    expect(sellingCards(state)).toEqual([]);
  });
});

describe("organisations", () => {
  test("suspended, deletion requested and ended are separate, and one of any opens its own page", () => {
    const cards = organisationCards([
      { code: "acme", name: "Acme", status: "suspended", deleted_at: null },
      { code: "bolt", name: "Bolt", status: "deleted", deleted_at: "2026-09-01T00:00:00Z" },
      { code: "core", name: "Core", status: "deleted", deleted_at: "2026-09-01T00:00:00Z" },
      { code: "dash", name: "Dash", status: "active" },
      { code: "echo", name: "Echo", status: "suspended", deleted_at: "2026-09-12T00:00:00Z" },
    ]);
    expect(cards.map((c) => c.key)).toEqual(["suspended", "deletion-requested", "ended"]);
    expect(cards[0]!.sentence).toBe("Nobody in Acme can work while it is suspended.");
    expect(cards[1]!.sentence).toContain("Echo asked to be deleted");
    expect(cards[1]!.target).toEqual({ section: "customers", view: "organisations", org: "echo" });
    cards.splice(1, 1);
    expect(cards[0]!.target).toEqual({ section: "customers", view: "organisations", org: "acme" });
    expect(cards[1]!.target).toEqual({ section: "customers", view: "organisations" });
    expect(cards[1]!.sentence).toContain("Bolt and Core");
  });
});

describe("the page", () => {
  const card = (key: string, tone: "warn" | "bad"): TodayCard => ({
    key,
    figure: "1",
    title: key,
    sentence: key,
    tone,
    action: "Open",
    target: { section: "today", view: "today" },
  });

  test("the serious come first, and a failed door keeps everybody else's cards", () => {
    const summary = summariseToday([
      { key: "one", label: "One", state: "ready", cards: [card("w", "warn")] },
      { key: "two", label: "Two", state: "error", error: new Error("refused") },
      { key: "three", label: "Three", state: "ready", cards: [card("b", "bad")] },
      { key: "four", label: "Four", state: "pending" },
    ]);
    expect(summary.cards.map((c) => c.key)).toEqual(["b", "w"]);
    expect(summary.failed.map((f) => f.key)).toEqual(["two"]);
    expect(summary.pending.map((p) => p.key)).toEqual(["four"]);
    expect(summary.allClear).toBe(false);
  });

  test("all clear only when every door answered and none found anything", () => {
    expect(
      summariseToday([
        { key: "one", label: "One", state: "ready", cards: [] },
        { key: "two", label: "Two", state: "ready", cards: [] },
      ]).allClear,
    ).toBe(true);
    expect(
      summariseToday([
        { key: "one", label: "One", state: "ready", cards: [] },
        { key: "two", label: "Two", state: "pending" },
      ]).allClear,
    ).toBe(false);
    expect(
      summariseToday([{ key: "one", label: "One", state: "error", error: "no" }]).allClear,
    ).toBe(false);
  });
});

describe("names in a sentence", () => {
  test("reads as a person would write it", () => {
    expect(listNames([])).toBe("");
    expect(listNames(["A"])).toBe("A");
    expect(listNames(["A", "B"])).toBe("A and B");
    expect(listNames(["A", "B", "C"])).toBe("A, B and C");
    expect(listNames(["A", "B", "C", "D"])).toBe("A, B and 2 others");
  });
});
