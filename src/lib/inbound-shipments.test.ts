import { describe, expect, test } from "bun:test";

import { inboundShipment, inboundShipments, weightWords } from "./inbound-shipments";

/** A row as public.erp_inbound_shipments answers it (20261004945000). */
const row = (over: Record<string, unknown> = {}) => ({
  shipment_id: "s1",
  document_id: "d1",
  document_number: "SHP-000001",
  order_id: "o1",
  order_number: "PO-000001",
  supplier: "Maison Brand",
  site_id: "site1",
  carrier: "Air freight",
  service_code: "standard",
  tracking_reference: "TRK-123",
  status: "booked",
  expected_arrival: "2026-10-04",
  late: false,
  cost_minor: 10000,
  currency: "GBP",
  weight_g: "12500.000000",
  ...over,
});

describe("a collection on its way", () => {
  test("reads the shipment, its order, the supplier, the carrier, the tracking reference and when it is expected", () => {
    expect(inboundShipment(row())).toEqual({
      shipmentId: "s1",
      documentId: "d1",
      number: "SHP-000001",
      orderId: "o1",
      orderNumber: "PO-000001",
      supplier: "Maison Brand",
      carrier: "Air freight",
      tracking: "TRK-123",
      expected: "2026-10-04",
      late: false,
      weightG: 12500,
    });
  });

  test("a late one says so, and one with no tracking reference has none", () => {
    expect(inboundShipment(row({ late: true }))?.late).toBe(true);
    expect(inboundShipment(row({ tracking_reference: null }))?.tracking).toBeNull();
  });

  test("a weight reads in grams or kilograms, and none, or nothing, reads as none", () => {
    expect(inboundShipment(row({ weight_g: null }))?.weightG).toBeNull();
    expect(inboundShipment(row({ weight_g: 0 }))?.weightG).toBeNull();
    expect(weightWords(12500)).toBe("12.5 kg");
    expect(weightWords(1000)).toBe("1 kg");
    expect(weightWords(750)).toBe("750 g");
    expect(weightWords(1234567)).toBe("1,234.6 kg");
  });

  test("the list keeps every row that is one, in the database's order", () => {
    const list = inboundShipments([row({ shipment_id: "s2", late: true }), row(), { nope: 1 }]);
    expect(list.map((s) => s.shipmentId)).toEqual(["s2", "s1"]);
    expect(inboundShipments(null)).toEqual([]);
  });
});
