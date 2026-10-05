import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import {
  defaultedValues,
  dropDefaultedValues,
  optionArgs,
  type FieldDefault,
} from "./dependent-options";

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

describe("converting a quotation from the strip (J-77)", () => {
  const sales = readFileSync(join(import.meta.dir, "..", "routes", "sales", "index.tsx"), "utf8");
  const convert = sales.slice(
    sales.indexOf('label: "Convert to a sales order"'),
    sales.indexOf('label: "Find a price"'),
  );

  test("the customer and the site arrive holding the quotation's", () => {
    expect(convert).toContain('defaultFrom: CONVERSION_DEFAULTS("party_id")');
    expect(convert).toContain('defaultFrom: CONVERSION_DEFAULTS("site_id")');
    expect(sales).toContain('fn: "erp_conversion_defaults"');
  });

  test("the quotation the strip chose is enough to ask for them", () => {
    // The strip hands the chosen quotation over as p_document_id, with no
    // picker of its own on the form.
    expect(optionArgs(conversion("party_id"), { p_document_id: "qt-1" })).toEqual({
      p_document_id: "qt-1",
    });
    expect(defaultedValues(fields, {}, { p_party_id: answer, p_site_id: answer })).toEqual({
      p_party_id: "sup-1",
      p_site_id: "site-1",
    });
  });

  test("it goes on to the order it made", () => {
    expect(convert).toContain("onDone: (result, openDocument)");
    expect(convert).toContain("madeDocumentId(result)");
  });
});

describe("a payment run's currency (5 October re-test)", () => {
  // Proposing a run arrived with the currency empty over twenty-five of them;
  // erp.propose_payment_run proposes for the first company by code, in its
  // base currency.
  const first: FieldDefault = { fn: "erp_entities", key: "base_currency", first: true };
  const companies = [
    { entity_id: "uk", code: "ACME", base_currency: "GBP" },
    { entity_id: "eu", code: "ACME-EU", base_currency: "EUR" },
  ];

  test("takes the first company's base currency from the list", () => {
    expect(
      defaultedValues([{ name: "p_currency", defaultFrom: first }], {}, { p_currency: companies }),
    ).toEqual({ p_currency: "GBP" });
  });

  test("a list is no answer to a default that does not ask for its first", () => {
    const plain: FieldDefault = { fn: "erp_entities", key: "base_currency" };
    expect(
      defaultedValues([{ name: "p_currency", defaultFrom: plain }], {}, { p_currency: companies }),
    ).toEqual({});
  });

  test("the Propose a payment run form declares it", () => {
    const modules = readFileSync(join(import.meta.dir, "modules.tsx"), "utf8");
    const propose = modules.slice(
      modules.indexOf('label: "Propose a payment run"'),
      modules.indexOf('label: "Approve a payment run"'),
    );
    expect(propose).toContain(
      'defaultFrom: { fn: "erp_entities", key: "base_currency", first: true }',
    );
  });
});
