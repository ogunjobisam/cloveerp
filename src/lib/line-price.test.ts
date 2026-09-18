import { describe, expect, test } from "bun:test";

import { priceLookupArgs, resolvedPrice, type PriceLookup } from "./line-price";

/**
 * The form asks what the database is about to ask.
 *
 * A goods receipt for ten sacks of oats showed a running total of GBP 0.00 and
 * the record came back at 10 x GBP 0.00 with nothing said. Two halves to that:
 * the database asked the wrong catalogue, and the form asked nothing at all.
 * This is the second half — the arguments the form sends, which have to be the
 * arguments the record will be written with or the two figures disagree again
 * for a new reason.
 */

const BUYING: PriceLookup = {
  fn: "erp_resolve_purchase_price",
  args: {
    p_item_id: "item_id",
    p_quantity: "quantity",
    p_party_id: "form.p_party_id",
    p_site_id: "form.p_site_id",
  },
  fixed: { p_site_id: "scope-site" },
  needs: ["p_item_id", "p_party_id"],
};

describe("what the form asks the catalogue", () => {
  test("a row that names a product, for a partner, asks about both", () => {
    expect(
      priceLookupArgs(BUYING, { item_id: "oats", quantity: "10" }, { p_party_id: "yorks" }),
    ).toEqual({
      p_item_id: "oats",
      p_quantity: "10",
      p_party_id: "yorks",
      p_site_id: "scope-site",
    });
  });

  test("a row with no product asks nothing, rather than asking about nothing", () => {
    expect(priceLookupArgs(BUYING, { quantity: "10" }, { p_party_id: "yorks" })).toBeNull();
  });

  test("a form with no partner asks nothing: there is no agreed price without one", () => {
    expect(priceLookupArgs(BUYING, { item_id: "oats", quantity: "10" }, {})).toBeNull();
  });

  test("the site the form shows beats the scope's, because that is the one that is sent", () => {
    const args = priceLookupArgs(
      BUYING,
      { item_id: "oats" },
      { p_party_id: "yorks", p_site_id: "chosen-site" },
    );
    expect(args?.["p_site_id"]).toBe("chosen-site");
  });

  test("the scope's site is carried when the form does not ask for one", () => {
    // The whole reason `fixed` exists: the site picker only appears when the
    // shell has not already answered it, and a lookup that left the site out
    // would show the general price while the record took the site's.
    const args = priceLookupArgs(BUYING, { item_id: "oats" }, { p_party_id: "yorks" });
    expect(args?.["p_site_id"]).toBe("scope-site");
  });

  test("an unanswered quantity is left out, not sent empty", () => {
    const args = priceLookupArgs(BUYING, { item_id: "oats" }, { p_party_id: "yorks" });
    expect(args).not.toHaveProperty("p_quantity");
  });

  test("a column with no lookup asks nothing", () => {
    expect(priceLookupArgs(undefined, { item_id: "oats" }, { p_party_id: "yorks" })).toBeNull();
  });
});

describe("what the form may show of the answer", () => {
  test("a price in the document's currency is the price", () => {
    expect(
      resolvedPrice(
        { amount_minor: 1850, currency: "GBP", source: "the supplier purchase list" },
        "amount_minor",
        "source",
        "GBP",
      ),
    ).toEqual({ minor: 1850, note: "the supplier purchase list" });
  });

  test("no price is no price, and the door's own sentence is what the line says", () => {
    expect(
      resolvedPrice(
        { amount_minor: null, source: "no price is on record for this supplier and item" },
        "amount_minor",
        "source",
        "GBP",
      ),
    ).toEqual({ minor: null, note: "no price is on record for this supplier and item" });
  });

  test("a price in another currency is no price here either", () => {
    // erp.add_document_line keeps a catalogue answer only when its currency is
    // the document's. A form that showed it would show a figure the record will
    // not carry — which is the exact fault this whole change is about.
    const held = resolvedPrice(
      { amount_minor: 2000, currency: "EUR" },
      "amount_minor",
      "source",
      "GBP",
    );
    expect(held.minor).toBeNull();
    expect(held.note).toContain("EUR");
    expect(held.note).toContain("GBP");
  });

  test("an answer that has not arrived yet is not a refusal", () => {
    expect(resolvedPrice(undefined, "amount_minor", "source", "GBP")).toEqual({
      minor: null,
      note: null,
    });
  });
});
