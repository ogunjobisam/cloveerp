import { describe, expect, test } from "bun:test";

import type { Field } from "../components/erp/action";
import type { ActionSpec } from "../components/erp/actions-bar";
import {
  dependentFields,
  emptyReason,
  optionArgs,
  optionList,
  pickerOptions,
} from "./dependent-options";
import { BOOK_A_COLLECTION, LOGISTICS, SET_FREIGHT_TERMS } from "./modules";

/**
 * Freight on a purchase order, and the carrier's service on every booking.
 *
 * The doors' suites prove what the database does (document_freight_terms,
 * orders_to_collect, carrier_service_options). What can be wrong here is the
 * call: Book a collection offered every open order, and Service was a box with
 * "standard" in it, which no rate card names (J-63, J-64, J-65).
 */

const select = (fields: Field[] | undefined, name: string) => {
  const f = (fields ?? []).find((x) => x.name === name);
  if (f?.kind !== "select") throw new Error(`${name} is not chosen from a list`);
  return f;
};

const logistics = (label: string): ActionSpec => {
  const a = (LOGISTICS.actions ?? []).find((x) => x.label === label);
  if (!a) throw new Error(`no ${label} on Logistics`);
  return a;
};

const carriers = [
  {
    code: "AIR",
    services: "EXPRESS",
    service_options: [{ code: "EXPRESS", transit_days: 1 }],
  },
  {
    code: "ROAD",
    services: "ECONOMY, NEXT_DAY",
    service_options: [
      { code: "ECONOMY", transit_days: 4 },
      { code: "NEXT_DAY", transit_days: 1 },
    ],
  },
  { code: "BARE", services: "", service_options: [] },
];

describe("Book a collection", () => {
  test("offers only the orders waiting to be collected, by their state's name", () => {
    const order = select(BOOK_A_COLLECTION.fields, "p_order");
    expect(BOOK_A_COLLECTION.fn).toBe("erp_ship_inbound");
    expect(BOOK_A_COLLECTION.permission).toBe("logistics.plan");
    expect(order.options.fn).toBe("erp_orders_to_collect");
    expect(order.options.label).toContain("state_name");
    expect(order.options.label).not.toContain("state");
    expect(emptyReason(order.options)).toContain("We collect");
  });

  test("says the order it booked, wherever it was booked from", () => {
    expect(BOOK_A_COLLECTION.invalidates).toContain("erp_orders_to_collect");
    expect(BOOK_A_COLLECTION.invalidates).toContain("erp_document");
  });
});

describe("Set freight terms", () => {
  test("offers every order not finished, by its state's name", () => {
    const order = select(SET_FREIGHT_TERMS.fields, "p_order");
    expect(SET_FREIGHT_TERMS.permission).toBe("procurement.order");
    expect(order.options.fn).toBe("erp_documents");
    expect(order.options.args).toMatchObject({ p_type_code: "purchase_order", p_actionable: true });
    expect(order.options.label).toContain("state_name");
    expect(order.options.label).not.toContain("state");
    expect(SET_FREIGHT_TERMS.invalidates).toContain("erp_orders_to_collect");
  });
});

describe("a carrier's service", () => {
  const forms: [string, ActionSpec][] = [
    ["Book a collection", BOOK_A_COLLECTION],
    ["Ship these deliveries", logistics("Ship these deliveries")],
    ["Book a shipment", logistics("Book a shipment")],
  ];

  test.each(forms)("is chosen from the carrier's rate card on %s, never typed", (_, form) => {
    const service = select(form.fields, "p_service_code");
    expect(service.placeholder).toBeUndefined();
    expect(service.options.fn).toBe("erp_carriers");
    expect(service.options.within).toEqual({
      field: "p_carrier_code",
      key: "code",
      path: "service_options",
    });
    // Changing the carrier empties the service chosen for the one before.
    expect(dependentFields(form.fields ?? [], "p_carrier_code")).toContain("p_service_code");
  });

  test("is the chosen carrier's, and waits for one to be chosen", () => {
    const service = select(BOOK_A_COLLECTION.fields, "p_service_code");
    expect(optionArgs(service.options, {})).toBeNull();
    const offered = (carrier: string) =>
      pickerOptions(
        service.options,
        optionList(service.options, carriers, { p_carrier_code: carrier }),
      ).map((o) => o.value);
    expect(offered("ROAD")).toEqual(["ECONOMY", "NEXT_DAY"]);
    expect(offered("AIR")).toEqual(["EXPRESS"]);
    expect(offered("BARE")).toEqual([]);
    expect(offered("ROAD")).not.toContain("standard");
  });

  test("says why a carrier offers none", () => {
    const service = select(BOOK_A_COLLECTION.fields, "p_service_code");
    expect(emptyReason(service.options)).toBe(
      "No service to choose: this carrier's rate card names none.",
    );
  });
});
