import { describe, expect, test } from "bun:test";

import { firstPerValue } from "./combo-options";

describe("the choices a type-or-pick box offers", () => {
  test("a value listed twice is offered once, as it was first listed", () => {
    // The reported case (J-152): reason codes exist per category, so the same
    // code came back once for customer returns and once for supplier returns.
    expect(
      firstPerValue([
        { value: "WRONG_QUANTITY", label: "Wrong quantity (customer)" },
        { value: "ORDERED_IN_ERROR", label: "Ordered in error" },
        { value: "WRONG_QUANTITY", label: "Wrong quantity (supplier)" },
      ]),
    ).toEqual([
      { value: "WRONG_QUANTITY", label: "Wrong quantity (customer)" },
      { value: "ORDERED_IN_ERROR", label: "Ordered in error" },
    ]);
  });

  test("a list with nothing repeated is unchanged, in its order", () => {
    const rows = [
      { value: "b", label: "B" },
      { value: "a", label: "A" },
    ];
    expect(firstPerValue(rows)).toEqual(rows);
  });

  test("an empty list offers nothing", () => {
    expect(firstPerValue([])).toEqual([]);
  });
});
