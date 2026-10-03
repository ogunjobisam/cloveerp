import { describe, expect, test } from "bun:test";

import {
  noticeOpen,
  noticePayload,
  orderNotices,
  shippingNotice,
  shippingNotices,
  ssccIsValid,
  ssccOf,
  type NoticeForm,
} from "./shipping-notices";

/** A notice as erp.shipping_notice writes it (20261005000000). */
const NOTICE = {
  notice_id: "n1",
  notice: "ASN-PO-000001-1",
  order_id: "o1",
  order: "PO-000001",
  supplier: "Brand Ltd",
  status: "part_received",
  ship_date: "2026-10-03",
  expected_arrival: "2026-10-08",
  late: false,
  carrier: "DHL",
  tracking_reference: "JD0001",
  supplier_reference: "DN-77",
  note: null,
  sent_via: "supplier",
  receipt: "GRN-000004",
  receipt_id: "g1",
  differences: [{ order_line_id: "l1", line_no: 10, notified: 4, received: 3, kind: "short" }],
  lines: [
    {
      order_line_id: "l1",
      line_no: 10,
      description: "Coat",
      quantity: "6.000000",
      received_quantity: "6.000000",
    },
    {
      order_line_id: "l2",
      line_no: 20,
      description: "Scarf",
      quantity: 10,
      received_quantity: null,
    },
  ],
  cartons: [
    { sscc: "350123451234567894", contents: [], received_at: "2026-10-08T09:00:00Z" },
    { sscc: "350123451234567900", contents: [], received_at: null },
  ],
};

describe("a shipping notice as the database writes it", () => {
  test("reads every field, numbers from numeric text", () => {
    const n = shippingNotice(NOTICE);
    expect(n?.status).toBe("part_received");
    expect(n?.lines[0]?.quantity).toBe(6);
    expect(n?.lines[1]?.receivedQuantity).toBeNull();
    expect(n?.differences[0]?.kind).toBe("short");
    expect(n?.cartons[1]?.receivedAt).toBeNull();
    expect(n?.sentVia).toBe("supplier");
    expect(n && noticeOpen(n)).toBe(true);
  });

  test("is nothing without its ids, and an unknown status reads as on its way", () => {
    expect(shippingNotice({ notice: "x" })).toBeNull();
    expect(shippingNotice(null)).toBeNull();
    expect(shippingNotice({ ...NOTICE, status: "lost" })?.status).toBe("notified");
  });

  test("goods-in's list and an order's page", () => {
    expect(shippingNotices([NOTICE, null, 3])).toHaveLength(1);
    expect(shippingNotices(null)).toEqual([]);
    const o = orderNotices({
      order_id: "o1",
      notices: [NOTICE],
      open: [{ order_line_id: "l1", line_no: 10, open: "0.000000" }],
    });
    expect(o.notices).toHaveLength(1);
    expect(o.open[0]?.open).toBe(0);
  });
});

describe("a carton's label", () => {
  test("is read bare, bracketed, after its identifier or a scanner's prefix", () => {
    expect(ssccOf("350123451234567894")).toBe("350123451234567894");
    expect(ssccOf("(00) 3501 2345 1234 5678 94")).toBe("350123451234567894");
    expect(ssccOf("00350123451234567894")).toBe("350123451234567894");
    expect(ssccOf("]C100350123451234567894")).toBe("350123451234567894");
    expect(ssccOf("(01)05012345678900")).toBeNull();
    expect(ssccOf("")).toBeNull();
  });

  test("ends in its GS1 check digit", () => {
    expect(ssccIsValid("350123451234567894")).toBe(true);
    expect(ssccIsValid("350123451234567900")).toBe(true);
    expect(ssccIsValid("350123451234567895")).toBe(false);
    expect(ssccIsValid("35012345123456789")).toBe(false);
  });
});

describe("the notice a supplier sends", () => {
  const form: NoticeForm = {
    shipDate: "2026-10-03",
    expectedArrival: "2026-10-08",
    carrier: " DHL ",
    trackingReference: "",
    supplierReference: "DN-77",
    note: "",
    quantities: { l1: "6", l2: "", l3: "0" },
    cartons: [
      { sscc: "(00)350123451234567894", quantities: { l1: "6", l2: "" } },
      { sscc: "  ", quantities: { l1: "1" } },
    ],
  };

  test("sends only lines with a quantity, as numbers, and leaves blank fields out", () => {
    expect(noticePayload(form)).toEqual({
      ship_date: "2026-10-03",
      expected_arrival: "2026-10-08",
      carrier: "DHL",
      supplier_reference: "DN-77",
      lines: [{ order_line_id: "l1", quantity: 6 }],
      cartons: [{ sscc: "350123451234567894", contents: [{ order_line_id: "l1", quantity: 6 }] }],
    });
  });

  test("sends no cartons when none is labelled", () => {
    expect(noticePayload({ ...form, cartons: [] })).not.toHaveProperty("cartons");
  });
});
