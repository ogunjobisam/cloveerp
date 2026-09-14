import { describe, expect, test } from "bun:test";

import { defaultedValues, dropDefaultedValues, type FieldDefault } from "./dependent-options";

/**
 * A field that arrives holding a door's answer.
 *
 * Turning a requisition into a purchase order asked for the supplier and the
 * site with nothing chosen. The form now reads what the conversion would take
 * and holds it, editable; what can be wrong here is whose answer wins.
 */

const conversion = (key: string): FieldDefault => ({
  fn: "erp_conversion_defaults",
  argsFrom: { p_document_id: "p_document_id" },
  key,
});

const fields = [
  { name: "p_document_id" },
  { name: "p_party_id", defaultFrom: conversion("party_id") },
  { name: "p_site_id", defaultFrom: conversion("site_id") },
  { name: "p_note" },
];

const answer = { party_id: "sup-1", site_id: "site-1", party_source: "item_supply" };

describe("what a defaulted field holds", () => {
  test("the door's answer, while the person has not answered", () => {
    expect(
      defaultedValues(fields, { p_document_id: "rq-1" }, { p_party_id: answer, p_site_id: answer }),
    ).toEqual({ p_document_id: "rq-1", p_party_id: "sup-1", p_site_id: "site-1" });
  });

  test("the person's answer once given, even an empty one", () => {
    expect(
      defaultedValues(
        fields,
        { p_document_id: "rq-1", p_party_id: "sup-2", p_site_id: "" },
        { p_party_id: answer, p_site_id: answer },
      ),
    ).toEqual({ p_document_id: "rq-1", p_party_id: "sup-2", p_site_id: "" });
  });

  test("nothing, when the door has not answered or has no answer for it", () => {
    const values = { p_document_id: "rq-1" };
    expect(defaultedValues(fields, values, {})).toEqual(values);
    expect(
      defaultedValues(fields, values, {
        p_party_id: { party_id: null, site_id: "site-1" },
        p_site_id: [answer],
      }),
    ).toEqual(values);
  });

  test("a field with no default is never filled", () => {
    expect(defaultedValues(fields, {}, { p_note: answer })).toEqual({});
  });
});

describe("when the choice a default follows changes", () => {
  test("the defaulted fields go back to the new choice's answer", () => {
    const values = { p_document_id: "rq-1", p_party_id: "sup-2", p_site_id: "", p_note: "x" };
    expect(dropDefaultedValues(fields, values, "p_document_id")).toEqual({
      p_document_id: "rq-1",
      p_note: "x",
    });
  });

  test("a change to anything else leaves every answer as it was", () => {
    const values = { p_document_id: "rq-1", p_party_id: "sup-2" };
    expect(dropDefaultedValues(fields, values, "p_note")).toBe(values);
  });
});
