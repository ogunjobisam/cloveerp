import { describe, expect, test } from "bun:test";

import { pickIntoRow, type RowColumn } from "../components/erp/action";

/**
 * A product carries its description, and a line takes it when it is picked.
 *
 * The owner's complaint was a goods receipt where every line needed "Unsalted
 * Butter" typed beside BUT-05, a product that already knew what it was. The
 * row editor now fills the line's description from the picked product. The
 * one way that can go wrong worth a test is the person's own words: a filler
 * that overwrites what somebody typed is worse than no filler, because it
 * throws work away silently.
 */

const PRODUCT: RowColumn = {
  name: "item_id",
  label: "Product",
  kind: "select",
  options: { fn: "erp_items", value: "item_id", label: ["code", "name"] },
};

const COLUMNS: RowColumn[] = [
  PRODUCT,
  { name: "quantity", label: "Quantity", kind: "number" },
  {
    name: "description",
    label: "Description",
    kind: "text",
    fillFrom: { column: "item_id", key: "description" },
  },
];

const BUTTER = { item_id: "b", code: "BUT-05", name: "Butter", description: "Unsalted Butter" };
const OATS = { item_id: "o", code: "OAT-25", name: "Oats", description: "Rolled oats, 25kg sack" };
const BARE = { item_id: "x", code: "BARE-1", name: "Bare", description: null };

describe("picking a product fills the line's description", () => {
  test("an empty line takes the product's description", () =>
    expect(
      pickIntoRow({}, COLUMNS, "item_id", "b", { picked: BUTTER, previous: undefined }),
    ).toEqual({ item_id: "b", description: "Unsalted Butter" }));

  test("a line whose description is blank takes it too", () =>
    expect(
      pickIntoRow({ description: "" }, COLUMNS, "item_id", "b", {
        picked: BUTTER,
        previous: undefined,
      }),
    ).toEqual({ item_id: "b", description: "Unsalted Butter" }));

  test("changing the product changes a description the last pick filled", () =>
    expect(
      pickIntoRow({ item_id: "b", description: "Unsalted Butter" }, COLUMNS, "item_id", "o", {
        picked: OATS,
        previous: BUTTER,
      }),
    ).toEqual({ item_id: "o", description: "Rolled oats, 25kg sack" }));

  test("a product with no description leaves the line blank, for the database to decide", () =>
    expect(
      pickIntoRow({ item_id: "b", description: "Unsalted Butter" }, COLUMNS, "item_id", "x", {
        picked: BARE,
        previous: BUTTER,
      }),
    ).toEqual({ item_id: "x", description: "" }));

  test("choosing no product clears what the last pick filled", () =>
    expect(
      pickIntoRow({ item_id: "b", description: "Unsalted Butter" }, COLUMNS, "item_id", "", {
        picked: undefined,
        previous: BUTTER,
      }),
    ).toEqual({ item_id: "", description: "" }));

  test("the rest of the row is kept", () =>
    expect(
      pickIntoRow({ quantity: "12" }, COLUMNS, "item_id", "b", {
        picked: BUTTER,
        previous: undefined,
      }),
    ).toEqual({ quantity: "12", item_id: "b", description: "Unsalted Butter" }));
});

describe("what the person typed is theirs", () => {
  test("typed before the product was picked, it stays", () =>
    expect(
      pickIntoRow({ description: "Butter, as agreed" }, COLUMNS, "item_id", "b", {
        picked: BUTTER,
        previous: undefined,
      }),
    ).toEqual({ item_id: "b", description: "Butter, as agreed" }));

  test("edited after the fill, it survives a change of product", () =>
    expect(
      pickIntoRow({ item_id: "b", description: "Unsalted Butter, 250g" }, COLUMNS, "item_id", "o", {
        picked: OATS,
        previous: BUTTER,
      }),
    ).toEqual({ item_id: "o", description: "Unsalted Butter, 250g" }));

  test("typing into the description is only typing", () =>
    expect(
      pickIntoRow(
        { item_id: "b", description: "Unsalted Butter" },
        COLUMNS,
        "description",
        "Salted",
      ),
    ).toEqual({ item_id: "b", description: "Salted" }));
});

describe("every other row editor is unchanged", () => {
  const PLAIN: RowColumn[] = [
    {
      name: "component_item_id",
      label: "Component",
      kind: "select",
      options: { fn: "erp_items", value: "item_id", label: ["code", "name"] },
    },
    { name: "note", label: "Note", kind: "text" },
  ];

  test("a column without fillFrom is never filled", () =>
    expect(
      pickIntoRow({}, PLAIN, "component_item_id", "b", { picked: BUTTER, previous: undefined }),
    ).toEqual({ component_item_id: "b" }));

  test("a pick with no record — a list of plain strings — fills nothing", () =>
    expect(
      pickIntoRow({}, COLUMNS, "item_id", "b", { picked: undefined, previous: undefined }),
    ).toEqual({ item_id: "b" }));

  test("a value that is not text is written as text; a record without the key fills nothing", () =>
    expect(
      pickIntoRow(
        {},
        [
          PRODUCT,
          {
            name: "pack",
            label: "Pack",
            kind: "number",
            fillFrom: { column: "item_id", key: "pack_size" },
          },
          {
            name: "gtin",
            label: "GTIN",
            kind: "text",
            fillFrom: { column: "item_id", key: "gtin" },
          },
        ],
        "item_id",
        "b",
        { picked: { ...BUTTER, pack_size: 12 }, previous: undefined },
      ),
    ).toEqual({ item_id: "b", pack: "12" }));
});
