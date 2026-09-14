import { describe, expect, test } from "bun:test";

import { pickDocument, pickLine } from "../components/erp/actions-bar";

/**
 * A document picker offers only what can still move.
 *
 * The owner found "Send this requisition back" offering a cancelled
 * requisition. The database refused it on submit, but a picker is for acting,
 * and offering the end of a process as something to act on is the fault. So
 * every pickDocument asks erp_documents for actionable documents, and one that
 * fronts a transition also names the transition, so the list holds only the
 * documents whose current state allows it. A line picker that fronts an action
 * asks erp_document_lines for open lines only.
 *
 * The filtering is the database's and its suite proves it. What can be wrong
 * here is the request: an argument left off, or one sent empty.
 */

function argsOf(
  field: ReturnType<typeof pickDocument>,
  fn = "erp_documents",
): Record<string, unknown> {
  if (field.kind !== "select") throw new Error(`the picker returned a ${field.kind} field`);
  expect(field.options.fn).toBe(fn);
  return field.options.args ?? {};
}

describe("pickDocument", () => {
  test("always asks for documents that can still move", () => {
    expect(argsOf(pickDocument("requisition"))).toEqual({
      p_type_code: "requisition",
      p_limit: 200,
      p_actionable: true,
    });
  });

  test("keeps its name, label and requiredness when a filter is given", () => {
    const field = pickDocument("purchase_order", "p_order_id", "Order", false, {
      transition: "approve",
    });
    expect(field.name).toBe("p_order_id");
    expect(field.label).toBe("Order");
    expect(field.required).toBe(false);
  });

  test("names the transition when the action fronts one", () => {
    expect(
      argsOf(
        pickDocument("requisition", "p_document_id", "Requisition", true, { transition: "reject" }),
      ),
    ).toEqual({
      p_type_code: "requisition",
      p_limit: 200,
      p_actionable: true,
      p_transition_code: "reject",
    });
  });

  test("sends no transition code when none is named", () => {
    const filters: ({ transition?: string } | undefined)[] = [undefined, {}, { transition: "" }];
    for (const filter of filters) {
      const args = argsOf(
        pickDocument("requisition", "p_document_id", "Requisition", true, filter),
      );
      expect("p_transition_code" in args).toBe(false);
      expect(args["p_actionable"]).toBe(true);
    }
  });
});

describe("pickLine", () => {
  test("asks for every line unless told the action needs open ones", () => {
    expect(argsOf(pickLine("purchase_order"), "erp_document_lines")).toEqual({
      p_type_code: "purchase_order",
      p_limit: 200,
    });
    expect(
      "p_open_only" in
        argsOf(
          pickLine("purchase_order", "p_order_line_id", "Order line", { openOnly: false }),
          "erp_document_lines",
        ),
    ).toBe(false);
  });

  test("names the document states when the action needs them, and never an empty list", () => {
    const field = pickLine("purchase_order", "p_order_line_id", "Order line", {
      openOnly: true,
      states: ["sent", "partially_received"],
    });
    expect(argsOf(field, "erp_document_lines")).toEqual({
      p_type_code: "purchase_order",
      p_limit: 200,
      p_open_only: true,
      p_document_states: ["sent", "partially_received"],
    });
    expect(
      "p_document_states" in
        argsOf(
          pickLine("purchase_order", "p_order_line_id", "Order line", { states: [] }),
          "erp_document_lines",
        ),
    ).toBe(false);
  });

  test("asks for open lines when the action acts on one", () => {
    const field = pickLine("sales_order", "p_line_id", "Sales order line", { openOnly: true });
    expect(field.name).toBe("p_line_id");
    expect(field.label).toBe("Sales order line");
    expect(argsOf(field, "erp_document_lines")).toEqual({
      p_type_code: "sales_order",
      p_limit: 200,
      p_open_only: true,
    });
  });
});
