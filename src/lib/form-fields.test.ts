import { describe, expect, test } from "bun:test";

import { fieldsFor } from "./form-fields";

const invoice = [
  { name: "p_delivery_id" },
  { name: "p_allow_self_invoice", permission: "administration.promote" },
  { name: "p_self_invoice_reason", permission: "administration.promote" },
];

describe("the fields a form asks", () => {
  test("a field naming no permission is asked of everybody", () => {
    expect(fieldsFor(invoice, () => false).map((f) => f.name)).toEqual(["p_delivery_id"]);
  });

  test("a field naming a permission is asked of somebody holding it", () => {
    expect(
      fieldsFor(invoice, (code) => code === "administration.promote").map((f) => f.name),
    ).toEqual(["p_delivery_id", "p_allow_self_invoice", "p_self_invoice_reason"]);
  });

  test("holding another permission asks nothing more", () => {
    expect(fieldsFor(invoice, (code) => code === "sales.invoice").map((f) => f.name)).toEqual([
      "p_delivery_id",
    ]);
  });
});
