import { describe, expect, test } from "bun:test";

import { DELIVER_AN_ORDER, DELIVER_THIS_ORDER, deliveryFromOrderArgs, LOGISTICS } from "./modules";

/**
 * A delivery comes from its sales order.
 *
 * The door's own suite proves what the database does with the call. What can be
 * wrong here is the call: the orders offered, the rows the line editor arrives
 * holding, and what is sent when the person changed nothing, lowered a
 * quantity, cleared one or removed every line.
 */

const fields = DELIVER_AN_ORDER.fields ?? [];

describe("the form", () => {
  test("names the door and the permission the door authorises", () => {
    expect(DELIVER_AN_ORDER.fn).toBe("erp_create_delivery_from_order");
    expect(DELIVER_AN_ORDER.permission).toBe("sales.despatch");
    expect(DELIVER_THIS_ORDER.fn).toBe(DELIVER_AN_ORDER.fn);
    expect(DELIVER_THIS_ORDER.permission).toBe(DELIVER_AN_ORDER.permission);
    expect(DELIVER_THIS_ORDER.code).not.toBe(DELIVER_AN_ORDER.fn);
  });

  test("offers only sales orders that can still be despatched", () => {
    const order = fields.find((f) => f.name === "p_order_id");
    if (order?.kind !== "select") throw new Error("the order is not chosen from a list");
    expect(order.options.fn).toBe("erp_documents");
    expect(order.options.args).toEqual({
      p_type_code: "sales_order",
      p_limit: 200,
      p_states: ["confirmed", "picking"],
    });
  });

  test("arrives holding the open lines of the order chosen, at what is left of each", () => {
    const lines = fields.find((f) => f.name === "p_lines");
    if (lines?.kind !== "rows") throw new Error("the lines are not a line editor");
    expect(lines.seed?.fn).toBe("erp_deliverable_lines");
    expect(lines.seed?.argsFrom).toEqual({ p_order_id: "p_order_id" });
    expect(lines.seed?.fill).toEqual({ line_id: "line_id", quantity: "open_quantity" });
    expect(lines.columns.map((c) => c.name)).toEqual(["line_id", "quantity"]);
  });

  test("is on the Despatch bar", () => {
    expect(LOGISTICS.actions).toContain(DELIVER_AN_ORDER);
  });
});

describe("what it sends", () => {
  test("no lines at all when the person changed nothing, which delivers every open line", () => {
    expect(deliveryFromOrderArgs({ p_order_id: "o1" }, { lists: {}, rows: {} })).toEqual({
      p_order_id: "o1",
      p_lines: null,
    });
    expect(deliveryFromOrderArgs({ p_order_id: "o1" })).toEqual({
      p_order_id: "o1",
      p_lines: null,
    });
  });

  test("each row as a line and a number, and a cleared quantity as the rest of that line", () => {
    const rows = {
      p_lines: [
        { line_id: "a", quantity: "4" },
        { line_id: "b", quantity: "" },
        { line_id: "", quantity: "9" },
      ],
    };
    expect(deliveryFromOrderArgs({ p_order_id: "o1" }, { lists: {}, rows })).toEqual({
      p_order_id: "o1",
      p_lines: [{ line_id: "a", quantity: 4 }, { line_id: "b" }],
    });
  });

  test("an empty list when every line was removed, which the door refuses by name", () => {
    expect(
      deliveryFromOrderArgs({ p_order_id: "o1" }, { lists: {}, rows: { p_lines: [] } }),
    ).toEqual({ p_order_id: "o1", p_lines: [] });
  });
});

/**
 * The order-line picker says what an empty list means.
 *
 * It reads erp_deliverable_lines(order), so it is empty for the order in front of the
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

  test("and the sentence says what is true of a deliver order", () => {
    expect(line?.options?.empty).toContain("nothing left to deliver");
  });
});
