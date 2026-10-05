/**
 * Advance shipping notices (20261005000000): what a supplier, or the buyer for
 * them, says is on its way against a sent order — when it left and arrives,
 * with whom, what of each line it holds, and the cartons by their SSCC — and,
 * once goods-in has received it, how what arrived differed.
 *
 * Read from public.erp_shipping_notices (goods-in's list) and
 * public.erp_order_shipping_notices (an order's page); sent to
 * public.erp_supplier_notify_shipment (the supplier's link) and
 * public.erp_record_shipping_notice (the buyer).
 */

import type { RowSeed } from "./dependent-options";

export type NoticeStatus = "notified" | "part_received" | "received" | "cancelled";

export type NoticeLine = {
  orderLineId: string;
  lineNo: number;
  description: string;
  quantity: number;
  receivedQuantity: number | null;
};

export type NoticeCarton = { sscc: string; receivedAt: string | null };

export type NoticeDifference = {
  orderLineId: string;
  lineNo: number | null;
  notified: number;
  received: number;
  kind: "short" | "over" | "not_notified";
};

export type ShippingNotice = {
  noticeId: string;
  notice: string;
  orderId: string;
  order: string;
  supplier: string;
  status: NoticeStatus;
  shipDate: string | null;
  expectedArrival: string | null;
  late: boolean;
  carrier: string | null;
  trackingReference: string | null;
  supplierReference: string | null;
  note: string | null;
  /** Why the buyer cancelled it, once it is cancelled (J-126). */
  cancelledReason: string | null;
  sentVia: "supplier" | "buyer";
  receipt: string | null;
  receiptId: string | null;
  differences: NoticeDifference[];
  lines: NoticeLine[];
  cartons: NoticeCarton[];
};

/** What the supplier, or the buyer, says is on its way. */
export type NoticePayload = {
  ship_date?: string;
  expected_arrival: string;
  carrier?: string;
  tracking_reference?: string;
  supplier_reference?: string;
  note?: string;
  lines: { order_line_id: string; quantity: number }[];
  cartons?: { sscc: string; contents: { order_line_id: string; quantity: number }[] }[];
};

type Row = Record<string, unknown>;

const asRecord = (v: unknown): Row | null =>
  typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Row) : null;

const text = (v: unknown): string | null =>
  typeof v === "string" && v.trim() !== "" ? v.trim() : null;

const num = (v: unknown): number | null => {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" ? Number(v) : NaN;
  return Number.isFinite(n) ? n : null;
};

const list = (v: unknown): Row[] =>
  (Array.isArray(v) ? v : []).map(asRecord).filter((r): r is Row => r !== null);

const STATUSES: readonly NoticeStatus[] = ["notified", "part_received", "received", "cancelled"];
const KINDS: readonly NoticeDifference["kind"][] = ["short", "over", "not_notified"];

/** One notice as the database writes it, or null for anything else. */
export function shippingNotice(v: unknown): ShippingNotice | null {
  const r = asRecord(v);
  const noticeId = text(r?.["notice_id"]);
  const orderId = text(r?.["order_id"]);
  if (r === null || noticeId === null || orderId === null) return null;
  const status = r["status"];
  return {
    noticeId,
    notice: text(r["notice"]) ?? "",
    orderId,
    order: text(r["order"]) ?? "",
    supplier: text(r["supplier"]) ?? "",
    status: (STATUSES as readonly unknown[]).includes(status)
      ? (status as NoticeStatus)
      : "notified",
    shipDate: text(r["ship_date"]),
    expectedArrival: text(r["expected_arrival"]),
    late: r["late"] === true,
    carrier: text(r["carrier"]),
    trackingReference: text(r["tracking_reference"]),
    supplierReference: text(r["supplier_reference"]),
    note: text(r["note"]),
    cancelledReason: text(r["cancelled_reason"]),
    sentVia: r["sent_via"] === "buyer" ? "buyer" : "supplier",
    receipt: text(r["receipt"]),
    receiptId: text(r["receipt_id"]),
    differences: list(r["differences"]).map((d) => ({
      orderLineId: text(d["order_line_id"]) ?? "",
      lineNo: num(d["line_no"]),
      notified: num(d["notified"]) ?? 0,
      received: num(d["received"]) ?? 0,
      kind: (KINDS as readonly unknown[]).includes(d["kind"])
        ? (d["kind"] as NoticeDifference["kind"])
        : "short",
    })),
    lines: list(r["lines"])
      .map((l) => ({
        orderLineId: text(l["order_line_id"]) ?? "",
        lineNo: num(l["line_no"]) ?? 0,
        description: text(l["description"]) ?? "",
        quantity: num(l["quantity"]) ?? 0,
        receivedQuantity: num(l["received_quantity"]),
      }))
      .filter((l) => l.orderLineId !== ""),
    cartons: list(r["cartons"])
      .map((c) => ({ sscc: text(c["sscc"]) ?? "", receivedAt: text(c["received_at"]) }))
      .filter((c) => c.sscc !== ""),
  };
}

/** Goods-in's list: the open notices, late first. */
export function shippingNotices(result: unknown): ShippingNotice[] {
  return (Array.isArray(result) ? result : [])
    .map(shippingNotice)
    .filter((n): n is ShippingNotice => n !== null);
}

/** An order's notices, newest first, and what of each line is still open. */
export function orderNotices(result: unknown): {
  notices: ShippingNotice[];
  open: { orderLineId: string; lineNo: number; open: number }[];
} {
  const r = asRecord(result);
  return {
    notices: shippingNotices(r?.["notices"]),
    open: list(r?.["open"])
      .map((o) => ({
        orderLineId: text(o["order_line_id"]) ?? "",
        lineNo: num(o["line_no"]) ?? 0,
        open: num(o["open"]) ?? 0,
      }))
      .filter((o) => o.orderLineId !== ""),
  };
}

export const noticeOpen = (n: Pick<ShippingNotice, "status">): boolean =>
  n.status === "notified" || n.status === "part_received";

/**
 * What a notice holds, in a few words for goods-in's list: "6 × Coat, 10 ×
 * Scarf", the first `shown` lines and a count of the rest ("+3"). Goods-in's
 * row named the order and the supplier only, so two notices against one order
 * could not be told apart without opening a dialog (J-57). Data, not words:
 * nothing here goes through ui().
 */
export function noticeLineSummary(lines: readonly NoticeLine[], shown = 2): string {
  const amount = (q: number) => (Number.isInteger(q) ? String(q) : String(Number(q.toFixed(4))));
  const said = lines
    .slice(0, shown)
    .map((l) =>
      l.description === "" ? amount(l.quantity) : `${amount(l.quantity)} × ${l.description}`,
    )
    .join(", ");
  const rest = lines.length - shown;
  return rest > 0 ? `${said} +${rest}` : said;
}

/**
 * "What is on its way" arrives holding every line of the order at what is
 * still open for a notice, so a notice is not recorded holding nothing (J-60).
 */
export const recordNoticeSeed = (orderId: string): RowSeed => ({
  fn: "erp_order_shipping_notices",
  args: { p_order: orderId },
  path: "open",
  fill: { order_line_id: "order_line_id", quantity: "open" },
});

/**
 * "Receive what arrived" arrives holding the notice's own lines at what it
 * said (J-59), read from the order's notices: the notice is the one the
 * dialog was opened on, prefilled as p_notice.
 */
export const arrivedSeed = (orderId: string): RowSeed => ({
  fn: "erp_order_shipping_notices",
  args: { p_order: orderId },
  path: "notices",
  within: { field: "p_notice", key: "notice_id", path: "lines" },
  fill: { order_line_id: "order_line_id", quantity: "quantity" },
});

/**
 * The lines a recorded notice holds, from the rows as typed: a row with no
 * line, or nothing above nought on it, is not in this shipment. A line already
 * notified in full arrives in the editor at nought and is left out here.
 */
export function noticeLinesTyped(
  rows: readonly Record<string, string>[],
): { order_line_id: string; quantity: number }[] {
  return rows.flatMap((row) => {
    const line = (row["order_line_id"] ?? "").trim();
    const quantity = num(row["quantity"] ?? "");
    return line !== "" && quantity !== null && quantity > 0
      ? [{ order_line_id: line, quantity }]
      : [];
  });
}

/**
 * The cartons a recorded notice holds, from the rows as typed: one row per
 * line a carton holds, grouped by the SSCC on its label (J-70). A row with no
 * label, no line or nothing above nought is left out; the label is sent as the
 * database reads a scan, eighteen digits, where it can be read that way. The
 * database refuses cartons that do not hold exactly what the lines say.
 */
export function noticeCartonsTyped(
  rows: readonly Record<string, string>[],
): { sscc: string; contents: { order_line_id: string; quantity: number }[] }[] {
  const cartons = new Map<string, { order_line_id: string; quantity: number }[]>();
  for (const row of rows) {
    const label = (row["sscc"] ?? "").trim();
    const line = (row["order_line_id"] ?? "").trim();
    const quantity = num(row["quantity"] ?? "");
    if (label === "" || line === "" || quantity === null || quantity <= 0) continue;
    const sscc = ssccOf(label) ?? label;
    cartons.set(sscc, [...(cartons.get(sscc) ?? []), { order_line_id: line, quantity }]);
  }
  return [...cartons].map(([sscc, contents]) => ({ sscc, contents }));
}

/** A quantity as a person reads it: 6, 2.5, never 6.0000. */
const quantityText = (v: unknown): string => {
  const n = num(v);
  return n === null ? "" : Number.isInteger(n) ? String(n) : String(Number(n.toFixed(4)));
};

/**
 * What an order line offered in a picker says (J-61): its product, what was
 * ordered and, where the screen knows it, what is still open for a notice.
 * The line pickers read "RM-300 — 6", and the 6 was the ordered quantity,
 * not the open one it was taken for. `open` is null where the screen does not
 * know it; the words around these values are the screen's, through ui().
 */
export function orderLineWords(
  row: Record<string, unknown>,
  open?: ReadonlyMap<string, number>,
): { words: { item: string; quantity: string }; open: string | null } {
  const item = [text(row["item"]), text(row["description"])].filter((x) => x !== null).join(" ");
  const known = open?.get(text(row["line_id"]) ?? "");
  return {
    words: { item, quantity: quantityText(row["quantity"]) },
    open: known === undefined ? null : quantityText(known),
  };
}

/** What a line of an order still to receive says in the receive picker (J-61). */
export function receivableLineWords(row: Record<string, unknown>): {
  line: string;
  item: string;
  open: string;
} {
  return {
    line: quantityText(row["line_no"]),
    item: [text(row["item"]), text(row["description"])].filter((x) => x !== null).join(" "),
    open: quantityText(row["open_quantity"]),
  };
}

export function noticeWords(s: NoticeStatus): {
  words: string;
  tone: "ok" | "warn" | "bad" | "muted";
} {
  switch (s) {
    case "notified":
      return { words: "On its way", tone: "muted" };
    case "part_received":
      return { words: "Part received", tone: "warn" };
    case "received":
      return { words: "Received", tone: "ok" };
    case "cancelled":
      return { words: "Cancelled", tone: "bad" };
  }
}

export function differenceWords(kind: NoticeDifference["kind"]): string {
  switch (kind) {
    case "short":
      return "Short";
    case "over":
      return "Over";
    case "not_notified":
      return "Not notified";
  }
}

/**
 * The SSCC a scan or a typed label carries, as erp.sscc_of reads it: eighteen
 * digits bare, or after the application identifier (00), with brackets,
 * spaces and a scanner's symbology prefix ignored. Null for anything else.
 */
export function ssccOf(scan: string): string | null {
  // FNC1, the group separator a GS1-128 scan may carry.
  const gs = String.fromCharCode(29);
  const digits = scan
    .trim()
    .replace(/^\][A-Za-z][0-9]/, "")
    .split("")
    .filter((ch) => ch !== "(" && ch !== ")" && ch !== gs && ch.trim() !== "")
    .join("");
  if (/^[0-9]{18}$/.test(digits)) return digits;
  if (/^00[0-9]{18}$/.test(digits)) return digits.slice(2);
  return null;
}

/** Whether eighteen digits end in their GS1 check digit, as erp.sscc_is_valid. */
export function ssccIsValid(sscc: string): boolean {
  if (!/^[0-9]{18}$/.test(sscc)) return false;
  let sum = 0;
  for (let i = 0; i < 17; i++) sum += Number(sscc[i]) * (i % 2 === 0 ? 3 : 1);
  return (10 - (sum % 10)) % 10 === Number(sscc[17]);
}

/** What the supplier's form holds, as typed. */
export type NoticeForm = {
  shipDate: string;
  expectedArrival: string;
  carrier: string;
  trackingReference: string;
  supplierReference: string;
  note: string;
  /** Quantity sending now, by order line, as typed. */
  quantities: Record<string, string>;
  cartons: { sscc: string; quantities: Record<string, string> }[];
};

const positive = (s: string | undefined): number | null => {
  const n = num(s ?? "");
  return n !== null && n > 0 ? n : null;
};

/**
 * The notice from what was typed: a line with no quantity is not in this
 * shipment, a carton with no SSCC is left out, and the database refuses what
 * does not add up.
 */
export function noticePayload(f: NoticeForm): NoticePayload {
  const lines = Object.entries(f.quantities).flatMap(([id, q]) => {
    const quantity = positive(q);
    return quantity === null ? [] : [{ order_line_id: id, quantity }];
  });
  const cartons = f.cartons
    .map((c) => ({
      sscc: ssccOf(c.sscc) ?? c.sscc.trim(),
      contents: Object.entries(c.quantities).flatMap(([id, q]) => {
        const quantity = positive(q);
        return quantity === null ? [] : [{ order_line_id: id, quantity }];
      }),
    }))
    .filter((c) => c.sscc !== "");
  const opt = (k: keyof NoticePayload, v: string) => (v.trim() === "" ? {} : { [k]: v.trim() });
  return {
    ...opt("ship_date", f.shipDate),
    expected_arrival: f.expectedArrival.trim(),
    ...opt("carrier", f.carrier),
    ...opt("tracking_reference", f.trackingReference),
    ...opt("supplier_reference", f.supplierReference),
    ...opt("note", f.note),
    lines,
    ...(cartons.length > 0 ? { cartons } : {}),
  };
}
