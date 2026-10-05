import { describe, expect, test } from "bun:test";

import type { Field } from "../components/erp/action";
import { emptyReason, pickerOptions } from "./dependent-options";
import { MODULES } from "./modules";

/**
 * Only a group parent is offered (J-94).
 *
 * The consolidated trial balance, the eliminations and the elimination itself
 * read a parent company's group ledger, and the database refuses a company
 * that has none. Their pickers offered every company; they now keep the ones
 * erp_entities says head a group (20261006191000). Adding a company to a group
 * still offers every company, because that is how one becomes a parent.
 */

const finance = MODULES.find((m) => m.path === "/finance");
if (!finance) throw new Error("no /finance module");

const parentField = (fields: readonly Field[] | undefined): Field | undefined =>
  (fields ?? []).find((f) => f.name === "p_parent_entity_id");

const companies = [
  { entity_id: "a", code: "ACME", name: "Acme", is_group_parent: true },
  { entity_id: "b", code: "SUB", name: "Subsidiary", is_group_parent: false },
  { entity_id: "c", code: "OLD", name: "A door older than the flag" },
];

describe("a group's parent is chosen from the companies that head a group", () => {
  const asked = [
    ...(finance.inquiries ?? []).filter((i) =>
      ["erp_consolidated_trial_balance", "erp_eliminations"].includes(i.fn),
    ),
    ...(finance.actions ?? []).filter((a) => a.fn === "erp_post_intercompany_elimination"),
  ];

  test("the two group reads and the elimination each pick a parent", () => {
    expect(asked.map((a) => a.fn).sort()).toEqual([
      "erp_consolidated_trial_balance",
      "erp_eliminations",
      "erp_post_intercompany_elimination",
    ]);
  });

  for (const a of asked) {
    test(`${a.fn} offers only a company that heads a group, and says why when none does`, () => {
      const f = parentField(a.fields);
      if (f?.kind !== "select") throw new Error(`${a.fn} does not pick its parent from a list`);
      expect(f.options.fn).toBe("erp_entities");
      expect(pickerOptions(f.options, companies).map((o) => o.value)).toEqual(["a"]);
      expect(pickerOptions(f.options, companies.slice(1))).toEqual([]);
      expect(emptyReason(f.options)).toContain("Add a company to a group");
    });
  }

  test("adding a company to a group still offers every company as the parent", () => {
    const add = (finance.actions ?? []).find((a) => a.fn === "erp_configure_consolidation");
    const f = parentField(add?.fields);
    if (f?.kind !== "select") throw new Error("the parent is not picked from a list");
    expect(pickerOptions(f.options, companies).map((o) => o.value)).toEqual(["a", "b", "c"]);
  });
});
