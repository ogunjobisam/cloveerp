import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import {
  awaitingOrders,
  confirmationWords,
  orderConfirmation,
  proposalShown,
  recordedAnswer,
  supplierAnswer,
  supplierOrder,
  tokenFromFragment,
} from "./supplier-confirmation";

/** The order a link names, as public.erp_supplier_response_peek answers it (20261004990000). */
const peek = {
  order: "PO-000001",
  organisation: "Clove Retail Ltd",
  supplier: "Maison Brand",
  currency: "GBP",
  order_date: "2026-10-03",
  status: "awaiting",
  can_respond: true,
  supplier_reference: null,
  note: null,
  decision_note: null,
  lines: [
    {
      line_id: "l1",
      line_no: 10,
      description: "Wool coat",
      item_code: "COAT",
      supplier_item_code: "MB-77",
      quantity: "10.000000",
      uom: "EA",
      unit_price_minor: 9000,
      required_date: "2026-10-20",
      confirmed_quantity: null,
      confirmed_date: null,
    },
    {
      line_id: "l2",
      line_no: 20,
      description: "Silk scarf",
      quantity: 10,
      uom: "EA",
      unit_price_minor: 1000,
      required_date: null,
    },
  ],
};

describe("the order a supplier's link names", () => {
  test("reads the order, whose it is, its lines and whether it may be answered", () => {
    const o = supplierOrder(peek);
    expect(o?.order).toBe("PO-000001");
    expect(o?.organisation).toBe("Clove Retail Ltd");
    expect(o?.canRespond).toBe(true);
    expect(o?.lines.map((l) => [l.lineNo, l.quantity, l.supplierItemCode])).toEqual([
      [10, 10, "MB-77"],
      [20, 10, null],
    ]);
    expect(supplierOrder(null)).toBeNull();
  });

  test("a confirmation sends only the lines that changed", () => {
    const o = supplierOrder(peek);
    if (!o) throw new Error("no order");
    expect(
      supplierAnswer(
        o,
        "confirm",
        { l1: { quantity: "8", date: "2026-10-27" }, l2: { quantity: "10", date: "" } },
        " SO-77 ",
        "Two on back order",
      ),
    ).toEqual({
      decision: "confirm",
      supplier_reference: "SO-77",
      note: "Two on back order",
      lines: [{ line_id: "l1", quantity: 8, date: "2026-10-27" }],
    });
    expect(supplierAnswer(o, "confirm", {}, "", "")).toEqual({ decision: "confirm" });
  });

  test("a decline sends no lines, only its reason", () => {
    const o = supplierOrder(peek);
    if (!o) throw new Error("no order");
    expect(
      supplierAnswer(o, "decline", { l1: { quantity: "1", date: "" } }, "", "Discontinued"),
    ).toEqual({
      decision: "decline",
      note: "Discontinued",
    });
  });

  test("the token is read from the link's fragment, and nothing else is a token", () => {
    const t = "a".repeat(64);
    expect(tokenFromFragment(`#t=${t}`)).toBe(t);
    expect(tokenFromFragment("#t=short")).toBeNull();
    expect(tokenFromFragment("")).toBeNull();
  });
});

describe("an order's answer on its page", () => {
  test("reads the status, who answered, the proposal and what the reader may do", () => {
    const c = orderConfirmation({
      order_id: "o1",
      order: "PO-000001",
      state: "sent",
      status: "changes_proposed",
      responded_via: "supplier",
      supplier_reference: "SO-77",
      proposal: [
        {
          line_id: "l1",
          line_no: 10,
          ordered_quantity: 10,
          quantity: 8,
          required_date: "2026-10-20",
          date: "2026-10-27",
        },
      ],
      received_any: false,
      lines: [],
      may_record: true,
      may_cancel: false,
    });
    expect(c?.status).toBe("changes_proposed");
    expect(c?.respondedVia).toBe("supplier");
    expect(c?.proposal[0]?.quantity).toBe(8);
    expect(c?.mayCancel).toBe(false);
    expect(orderConfirmation({})).toBeNull();
  });

  test("a line typed over still carries its product's code and name (J-157)", () => {
    const c = orderConfirmation({
      order_id: "o1",
      order: "PO-000001",
      status: "confirmed",
      lines: [
        {
          line_id: "l1",
          line_no: 10,
          description: "JT-A added line",
          item_code: "COAT",
          item_name: "Wool coat",
          quantity: "10.000000",
          confirmed_quantity: 10,
        },
      ],
    });
    expect(c?.lines[0]).toMatchObject({
      description: "JT-A added line",
      itemCode: "COAT",
      itemName: "Wool coat",
      quantity: 10,
    });
    const panel = readFileSync(
      join(import.meta.dir, "..", "components", "erp", "supplier-confirmation.tsx"),
      "utf8",
    );
    expect(panel).toContain(
      "<LineProduct name={lineName(l.itemCode, l.itemName, l.description)} />",
    );
  });

  test("a proposal is decided while it waits, kept once accepted, and gone once answered again (J-62)", () => {
    const proposal = [
      {
        lineId: "l1",
        lineNo: 10,
        orderedQuantity: 10,
        quantity: 8,
        requiredDate: "2026-10-20",
        date: "2026-10-27",
      },
    ];
    expect(proposalShown({ status: "changes_proposed", proposal })).toBe("to_decide");
    // Accepted: the line now reads 8, and the 10 that was ordered is kept here.
    expect(proposalShown({ status: "confirmed", proposal })).toBe("accepted");
    // Confirmed as ordered, rejected and waiting, or declined: nothing to show.
    expect(proposalShown({ status: "confirmed", proposal: [] })).toBeNull();
    expect(proposalShown({ status: "awaiting", proposal })).toBeNull();
    expect(proposalShown({ status: "declined", proposal: [] })).toBeNull();
  });

  test("the buyer records with changes as a confirmation that names it, and the other two as before (J-62)", () => {
    const rows = [
      { line_id: "l1", quantity: "8", date: "2026-10-27" },
      { line_id: "", quantity: "3", date: "" },
    ];
    expect(
      recordedAnswer({ decision: "with_changes", supplier_reference: " SO-77 ", note: "" }, rows),
    ).toEqual({
      decision: "confirm",
      with_changes: true,
      supplier_reference: "SO-77",
      lines: [{ line_id: "l1", quantity: 8, date: "2026-10-27" }],
    });
    // With changes and no line: sent as said, for the database to refuse.
    expect(recordedAnswer({ decision: "with_changes" }, [])).toEqual({
      decision: "confirm",
      with_changes: true,
    });
    expect(recordedAnswer({ decision: "confirm" }, [])).toEqual({ decision: "confirm" });
    expect(recordedAnswer({}, [])).toEqual({ decision: "confirm" });
    expect(recordedAnswer({ decision: "decline", note: "Discontinued" }, [])).toEqual({
      decision: "decline",
      note: "Discontinued",
    });
  });

  test("the waiting list keeps its order and marks the overdue", () => {
    expect(
      awaitingOrders([
        {
          order_id: "o1",
          order: "PO-1",
          supplier: "A",
          status: "declined",
          days_waiting: 1,
          overdue: false,
        },
        {
          order_id: "o2",
          order: "PO-2",
          supplier: "B",
          status: "awaiting",
          days_waiting: 5,
          overdue: true,
        },
        { nope: 1 },
      ]).map((o) => [o.order, o.overdue]),
    ).toEqual([
      ["PO-1", false],
      ["PO-2", true],
    ]);
  });

  test("every status reads in words", () => {
    expect(confirmationWords("confirmed")).toEqual({ words: "Confirmed", tone: "ok" });
    expect(confirmationWords("declined").tone).toBe("bad");
    expect(confirmationWords("awaiting").words).toBe("Awaiting confirmation");
  });
});
