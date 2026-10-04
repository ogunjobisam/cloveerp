import { describe, expect, test } from "bun:test";

import { missingRequired } from "./required-fields";

const FORM = [
  { name: "p_party_id", kind: "select", required: true },
  { name: "p_their_ref", kind: "text" },
  { name: "p_required_date", kind: "date", required: false },
  { name: "p_lines", kind: "rows", required: true },
];

describe("what a form is still missing", () => {
  test("an empty form names every required answer, in the order it asks them", () => {
    // The reported case: Create on a blank New goods receipt said nothing.
    expect(missingRequired(FORM, {}, {})).toEqual(["p_party_id", "p_lines"]);
  });

  test("an optional answer left blank is not missing", () => {
    expect(
      missingRequired(FORM, { p_party_id: "yorks" }, { p_lines: [{ item_id: "oats" }] }),
    ).toEqual([]);
  });

  test("a line editor holding only blank rows has no lines", () => {
    expect(
      missingRequired(FORM, { p_party_id: "yorks" }, { p_lines: [{}, { item_id: "  " }] }),
    ).toEqual(["p_lines"]);
  });

  test("whitespace is not an answer", () => {
    expect(missingRequired(FORM, { p_party_id: "   " }, { p_lines: [{ quantity: "10" }] })).toEqual(
      ["p_party_id"],
    );
  });

  test("a group of ticks needs one ticked", () => {
    const form = [{ name: "p_batches", kind: "multi", required: true }];
    expect(missingRequired(form, {}, {}, { p_batches: [] })).toEqual(["p_batches"]);
    expect(missingRequired(form, {}, {}, { p_batches: ["b1"] })).toEqual([]);
  });

  test("an inquiry asked with its required choice empty is missing it, so the door is not called", () => {
    // The reported case (J-96): a settlement statement asked with no partner
    // went to the door without its one argument, and the answer was worded as
    // "not installed". The inquiry form now checks this before it asks.
    const inquiry = [
      { name: "p_party_id", kind: "select", required: true },
      { name: "p_from", kind: "date" },
    ];
    expect(missingRequired(inquiry, {}, {})).toEqual(["p_party_id"]);
    expect(missingRequired(inquiry, { p_party_id: "yorks" }, {})).toEqual([]);
  });
});
