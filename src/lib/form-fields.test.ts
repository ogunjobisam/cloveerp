import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

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

describe("a required field says so before anything is pressed (J-104)", () => {
  const read = (p: string) => readFileSync(join(import.meta.dir, p), "utf8");

  test("the cost centre's Status arrives on Active, the one value a new cost centre takes", () => {
    const screen = read("../routes/finance/dimensions.tsx");
    const action = screen.slice(
      screen.indexOf('fn: "erp_upsert_cost_centre"'),
      screen.indexOf('invalidates: ["erp_cost_centres"'),
    );
    const status = action.slice(action.indexOf('name: "p_status"'));
    expect(status).toMatch(/^name: "p_status",[\s\S]*?required: true,[\s\S]*?default: "active",/);
  });

  test("the form marks a required field beside its label, for the eye only", () => {
    const form = read("../components/erp/action.tsx");
    expect(form).toMatch(/\{f\.required \? \(\s*<span aria-hidden="true"/);
  });
});
