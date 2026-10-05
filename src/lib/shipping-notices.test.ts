import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { seededRows } from "./dependent-options";
import { missingRequired } from "./required-fields";
import {
  arrivedSeed,
  noticeCartonsTyped,
  noticeLineSummary,
  noticeLinesTyped,
  noticeOpen,
  noticePayload,
  orderLineWords,
  recordNoticeSeed,
  orderNotices,
  receivableLineWords,
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
    expect(n?.cancelledReason).toBeNull();
    expect(n && noticeOpen(n)).toBe(true);
  });

  test("a cancelled notice keeps why it was cancelled (J-126)", () => {
    const n = shippingNotice({
      ...NOTICE,
      status: "cancelled",
      cancelled_reason: " The supplier split the delivery ",
    });
    expect(n?.status).toBe("cancelled");
    expect(n?.cancelledReason).toBe("The supplier split the delivery");
    expect(n && noticeOpen(n)).toBe(false);
    expect(shippingNotice({ ...NOTICE, cancelled_reason: "" })?.cancelledReason).toBeNull();
    const src = readFileSync(
      join(import.meta.dir, "..", "components", "erp", "shipping-notices.tsx"),
      "utf8",
    );
    const card = src.slice(src.indexOf("function NoticeCard"));
    expect(card).toMatch(/\{ui\("Why it is cancelled"\)\}: \{n\.cancelledReason\}/);
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

describe("goods-in's row says which notice and what it holds (J-57)", () => {
  const lines = shippingNotice(NOTICE)?.lines ?? [];

  test("the first two lines as quantity and product", () => {
    expect(noticeLineSummary(lines)).toBe("6 × Coat, 10 × Scarf");
  });

  test("and a count of the rest", () => {
    const more = [
      ...lines,
      { ...lines[1]!, orderLineId: "l3", description: "Hat", quantity: 2.5 },
      { ...lines[1]!, orderLineId: "l4", description: "Belt", quantity: 1 },
    ];
    expect(noticeLineSummary(more)).toBe("6 × Coat, 10 × Scarf +2");
    expect(noticeLineSummary(more, 3)).toBe("6 × Coat, 10 × Scarf, 2.5 × Hat +1");
  });

  test("nothing for a notice with no lines, and a quantity alone for a line with no name", () => {
    expect(noticeLineSummary([])).toBe("");
    expect(noticeLineSummary([{ ...lines[0]!, description: "" }])).toBe("6");
  });

  test("the row draws the notice's number and the summary", () => {
    const src = readFileSync(
      join(import.meta.dir, "..", "components", "erp", "shipping-notices.tsx"),
      "utf8",
    );
    const row = src.slice(src.indexOf("export function OnItsWay"));
    expect(row).toContain("{n.notice}</span>");
    expect(row).toContain("noticeLineSummary(n.lines)");
  });
});

/** The order's notices as erp_order_shipping_notices answers (20261005000000). */
const ORDER = {
  order_id: "o1",
  notices: [NOTICE],
  open: [
    { order_line_id: "l1", line_no: 10, open: 0 },
    { order_line_id: "l2", line_no: 20, open: 4 },
  ],
};

describe("a notice the buyer records holds lines (J-60)", () => {
  test("the editor arrives holding every line at what is still open", () => {
    expect(seededRows(recordNoticeSeed("o1"), ORDER, {})).toEqual([
      { order_line_id: "l1", quantity: "0" },
      { order_line_id: "l2", quantity: "4" },
    ]);
  });

  test("a line at nought, or with no line chosen, is not sent", () => {
    expect(
      noticeLinesTyped([
        { order_line_id: "l1", quantity: "0" },
        { order_line_id: "l2", quantity: "4" },
        { order_line_id: "", quantity: "2" },
        { order_line_id: "l3", quantity: "" },
        { order_line_id: "l4", quantity: "-1" },
      ]),
    ).toEqual([{ order_line_id: "l2", quantity: 4 }]);
  });

  test("the lines are required, so an empty notice never reaches the door", () => {
    const src = readFileSync(
      join(import.meta.dir, "..", "components", "erp", "shipping-notices.tsx"),
      "utf8",
    );
    const record = src.slice(src.indexOf("function RecordNotice"));
    expect(record).toMatch(
      /label: "What is on its way",[\s\S]{0,300}required: true,\s*seed: recordNoticeSeed\(orderId\)/,
    );
    expect(record).toContain("noticeLinesTyped(");
    expect(
      missingRequired([{ name: "lines", kind: "rows", required: true }], {}, { lines: [] }),
    ).toEqual(["lines"]);
  });
});

const SHIPPING_NOTICES_TSX = () =>
  readFileSync(join(import.meta.dir, "..", "components", "erp", "shipping-notices.tsx"), "utf8");

describe("a buyer's notice carries its cartons (J-70)", () => {
  test("rows are grouped into cartons by their label, a scan read as eighteen digits", () => {
    expect(
      noticeCartonsTyped([
        { sscc: "(00)350123451234567894", order_line_id: "l1", quantity: "6" },
        { sscc: "350123451234567900", order_line_id: "l2", quantity: "4" },
        { sscc: "350123451234567894", order_line_id: "l2", quantity: "2.5" },
      ]),
    ).toEqual([
      {
        sscc: "350123451234567894",
        contents: [
          { order_line_id: "l1", quantity: 6 },
          { order_line_id: "l2", quantity: 2.5 },
        ],
      },
      { sscc: "350123451234567900", contents: [{ order_line_id: "l2", quantity: 4 }] },
    ]);
  });

  test("a row with no label, no line or nothing above nought is left out, and none means no cartons", () => {
    expect(
      noticeCartonsTyped([
        { sscc: "", order_line_id: "l1", quantity: "6" },
        { sscc: "350123451234567894", order_line_id: "", quantity: "6" },
        { sscc: "350123451234567894", order_line_id: "l1", quantity: "0" },
        { sscc: "350123451234567894", order_line_id: "l1", quantity: "" },
      ]),
    ).toEqual([]);
    expect(noticeCartonsTyped([])).toEqual([]);
  });

  test("a label that is not a scan is sent as typed, for the database to refuse by name", () => {
    expect(noticeCartonsTyped([{ sscc: " BOX-1 ", order_line_id: "l1", quantity: "1" }])).toEqual([
      { sscc: "BOX-1", contents: [{ order_line_id: "l1", quantity: 1 }] },
    ]);
  });

  test("the buyer's dialog asks for cartons and sends them only when there are some", () => {
    const record = SHIPPING_NOTICES_TSX().slice(
      SHIPPING_NOTICES_TSX().indexOf("function RecordNotice"),
    );
    expect(record).toMatch(/name: "cartons",\s*label: "Cartons",/);
    expect(record).toContain('addLabel: "Add a carton"');
    expect(record).toContain("noticeCartonsTyped(");
    expect(record).toContain("...(cartons.length > 0 ? { cartons } : {})");
  });
});

describe("receiving what arrived arrives holding the notice's lines (J-59)", () => {
  test("the editor holds the notice's own lines at what it said, and only that notice's", () => {
    const second = { ...NOTICE, notice_id: "n2", lines: [{ order_line_id: "l9", quantity: 3 }] };
    const order = { ...ORDER, notices: [NOTICE, second] };
    expect(seededRows(arrivedSeed("o1"), order, { p_notice: "n1" })).toEqual([
      { order_line_id: "l1", quantity: "6.000000" },
      { order_line_id: "l2", quantity: "10" },
    ]);
    expect(seededRows(arrivedSeed("o1"), order, { p_notice: "n2" })).toEqual([
      { order_line_id: "l9", quantity: "3" },
    ]);
    expect(seededRows(arrivedSeed("o1"), order, {})).toEqual([]);
  });

  test("only a notice still wholly on its way is seeded, and the dialog names its notice", () => {
    const src = SHIPPING_NOTICES_TSX();
    expect(src).toContain('...(n.status === "notified" ? { seed: arrivedSeed(n.orderId) } : {})');
    const receive = src.slice(src.indexOf('title="Receive what arrived"'));
    expect(receive.slice(0, 600)).toContain("prefill={{ p_notice: n.noticeId }}");
  });
});

describe("a line picker says what its number is (J-61)", () => {
  test("an order line names its product and what was ordered", () => {
    expect(
      orderLineWords({ line_id: "l1", item: "RM-300", description: "Hex bolt", quantity: 6 }),
    ).toEqual({ words: { item: "RM-300 Hex bolt", quantity: "6" }, open: null });
  });

  test("and what is still open, where the screen knows it", () => {
    const open = new Map([
      ["l1", 2],
      ["l2", 0],
    ]);
    expect(orderLineWords({ line_id: "l1", item: "RM-300", quantity: "6.0000" }, open)).toEqual({
      words: { item: "RM-300", quantity: "6" },
      open: "2",
    });
    expect(orderLineWords({ line_id: "l2", item: "RM-301", quantity: 1.5 }, open).open).toBe("0");
    expect(orderLineWords({ line_id: "l3", item: "RM-302", quantity: 1 }, open).open).toBeNull();
  });

  test("a line to receive names its number, its product and what is left", () => {
    expect(
      receivableLineWords({
        line_no: 1,
        item: "RM-300",
        description: "Hex bolt",
        open_quantity: "4.500000",
      }),
    ).toEqual({ line: "1", item: "RM-300 Hex bolt", open: "4.5" });
  });

  test("each picker puts the word beside the number", () => {
    const notices = SHIPPING_NOTICES_TSX();
    expect(notices).toContain('ui("{item}: {open} of {quantity} still open")');
    expect(notices).toContain('ui("{item}: {quantity} ordered")');
    const answer = readFileSync(
      join(import.meta.dir, "..", "components", "erp", "supplier-confirmation.tsx"),
      "utf8",
    );
    expect(answer).toContain('ui("{item}: {quantity} ordered")');
  });
});
