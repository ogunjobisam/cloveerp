import { describe, expect, test } from "bun:test";

import {
  RECEIPT_FROM_ORDER_FIELDS,
  RECEIVE_AN_ORDER,
  RECEIVE_THIS_ORDER,
  receiptFromOrderArgs,
} from "./modules";

/**
 * Goods arrive against their order.
 *
 * The door's own suite proves what the database does with the call. What can be
 * wrong here is the call: the orders offered, the rows the line editor arrives
 * holding, and what is sent when the person changed nothing, lowered a
 * quantity, named a place or a batch, split a line or removed every line.
 */

const fields = RECEIPT_FROM_ORDER_FIELDS;

describe("the form", () => {
  test("names the door and the permission the door authorises", () => {
    expect(RECEIVE_AN_ORDER.fn).toBe("erp_create_receipt_from_order");
    expect(RECEIVE_AN_ORDER.permission).toBe("procurement.receive");
    expect(RECEIVE_THIS_ORDER.fn).toBe(RECEIVE_AN_ORDER.fn);
    expect(RECEIVE_THIS_ORDER.permission).toBe(RECEIVE_AN_ORDER.permission);
    expect(RECEIVE_THIS_ORDER.code).not.toBe(RECEIVE_AN_ORDER.fn);
  });

  test("offers only purchase orders sent to the supplier", () => {
    const order = fields.find((f) => f.name === "p_order_id");
    if (order?.kind !== "select") throw new Error("the order is not chosen from a list");
    expect(order.options.fn).toBe("erp_documents");
    expect(order.options.args).toEqual({
      p_type_code: "purchase_order",
      p_limit: 200,
      p_states: ["sent", "partially_received"],
    });
  });

  test("arrives holding the open lines of the order chosen, at what is left of each", () => {
    const lines = fields.find((f) => f.name === "p_lines");
    if (lines?.kind !== "rows") throw new Error("the lines are not a line editor");
    expect(lines.seed?.fn).toBe("erp_receivable_lines");
    expect(lines.seed?.argsFrom).toEqual({ p_order_id: "p_order_id" });
    expect(lines.seed?.fill).toEqual({ line_id: "line_id", quantity: "open_quantity" });
    expect(lines.columns.map((c) => c.name)).toEqual([
      "line_id",
      "quantity",
      "location_id",
      "batch_id",
    ]);
    const line = lines.columns.find((c) => c.name === "line_id");
    expect(line?.options?.fn).toBe("erp_receivable_lines");
  });

  test("asks for nothing the door does not take", () => {
    expect(fields.map((f) => f.name).sort()).toEqual(["p_lines", "p_order_id"]);
  });
});

describe("what it sends", () => {
  test("no lines at all when the person changed nothing, which receives every open line", () => {
    expect(receiptFromOrderArgs({ p_order_id: "o1" }, { lists: {}, rows: {} })).toEqual({
      p_order_id: "o1",
      p_lines: null,
    });
    expect(receiptFromOrderArgs({ p_order_id: "o1" })).toEqual({
      p_order_id: "o1",
      p_lines: null,
    });
  });

  test("each row as a line, a number, and the place and batch named; a cleared quantity as the rest of that line", () => {
    const rows = {
      p_lines: [
        { line_id: "a", quantity: "4", location_id: "bulk", batch_id: "" },
        { line_id: "a", quantity: "2", location_id: "", batch_id: "b7" },
        { line_id: "b", quantity: "", location_id: "", batch_id: "" },
        { line_id: "", quantity: "9", location_id: "bulk", batch_id: "b1" },
      ],
    };
    expect(receiptFromOrderArgs({ p_order_id: "o1" }, { lists: {}, rows })).toEqual({
      p_order_id: "o1",
      p_lines: [
        { line_id: "a", quantity: 4, location_id: "bulk" },
        { line_id: "a", quantity: 2, batch_id: "b7" },
        { line_id: "b" },
      ],
    });
  });

  test("an empty list when every line was removed, which the door refuses by name", () => {
    expect(
      receiptFromOrderArgs({ p_order_id: "o1" }, { lists: {}, rows: { p_lines: [] } }),
    ).toEqual({ p_order_id: "o1", p_lines: [] });
  });
});

/**
 * The order-line picker says what an empty list means.
 *
 * It reads erp_receivable_lines(order), so it is empty for the order in front of the
 * reader and never for the organisation — which is what it used to say.
 */
describe("the order-line picker names the order when it has nothing", () => {
  const rows = fields.find((f) => f.kind === "rows");
  const line =
    rows && rows.kind === "rows" ? rows.columns.find((c) => c.name === "line_id") : undefined;

  test("it follows the order and declares its own empty sentence", () => {
    expect(line?.options?.argsFrom).toEqual({ p_order_id: "p_order_id" });
    expect(line?.options?.empty).toContain("This order");
    expect(line?.options?.empty).not.toContain("organisation");
  });

  test("and the sentence says what is true of a receive order", () => {
    expect(line?.options?.empty).toContain("nothing left to receive");
  });
});
