import { describe, expect, test } from "bun:test";

import { emptyReason, optionArgs, optionList, pickerOptions } from "./dependent-options";
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

/**
 * Each row's Location and Batch are its own line's (J-58).
 *
 * They listed every location of the organisation, another site's and Despatch
 * among them, and every batch of every product, and on a plain product said
 * the list was empty for the organisation. erp_receivable_lines now answers
 * each line's places and batches; the columns read the row's own.
 */
describe("a row offers its own line's places and batches", () => {
  const rows = fields.find((f) => f.kind === "rows");
  const column = (name: string) =>
    rows && rows.kind === "rows" ? rows.columns.find((c) => c.name === name) : undefined;
  const B1 = { batch_id: "b1", batch_number: "B1", expires_on: "2027-01-01" };
  const ANSWER = [
    {
      line_id: "a",
      line_no: 1,
      item: "SER-1",
      open_quantity: 6,
      locations: [{ location_id: "bulk", code: "BULK", name: "Shelf" }],
      batches: [B1],
    },
    {
      line_id: "p",
      line_no: 2,
      item: "BOX-1",
      open_quantity: 4,
      locations: [{ location_id: "bulk", code: "BULK", name: "Shelf" }],
      batches: [],
    },
  ];

  test("both read the order's receivable lines, within the row's line", () => {
    for (const [name, path] of [
      ["location_id", "locations"],
      ["batch_id", "batches"],
    ] as const) {
      const options = column(name)?.options;
      expect(options?.fn).toBe("erp_receivable_lines");
      expect(options?.argsFrom).toEqual({ p_order_id: "p_order_id" });
      expect(options?.within).toEqual({ field: "line_id", key: "line_id", path });
    }
  });

  test("a row's batches are its line's, and a plain product's are none, said in its own words", () => {
    const batch = column("batch_id")?.options;
    if (!batch) throw new Error("no batch picker");
    const values = { p_order_id: "o1", line_id: "a" };
    expect(optionArgs(batch, values)).toEqual({ p_order_id: "o1" });
    expect(pickerOptions(batch, optionList(batch, ANSWER, values))).toEqual([
      { value: "b1", label: "B1 — 2027-01-01", record: B1 },
    ]);
    expect(optionList(batch, ANSWER, { ...values, line_id: "p" })).toEqual([]);
    expect(emptyReason(batch)).toBe(
      "No batch to choose: this product is not batch-controlled, or has no batch yet.",
    );
  });

  test("a row with no line chosen waits for it", () => {
    const location = column("location_id")?.options;
    if (!location) throw new Error("no location picker");
    expect(optionArgs(location, { p_order_id: "o1" })).toBeNull();
    expect(optionList(location, ANSWER, { p_order_id: "o1", line_id: "a" })).toEqual(
      ANSWER[0]!.locations,
    );
  });

  test("the order line says its number is what is left to receive (J-61)", () => {
    const line = column("line_id")?.options;
    if (!line) throw new Error("no line picker");
    const ui = (text: string) => text;
    expect(pickerOptions(line, ANSWER, ui)[0]?.label).toBe("Line 1: SER-1, 6 left to receive");
  });
});
