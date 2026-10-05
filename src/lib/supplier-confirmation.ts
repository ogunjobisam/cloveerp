/**
 * A purchase order's answer from its supplier (20261004990000): what the
 * supplier's page reads through its link (public.erp_supplier_response_peek),
 * the answer it sends back (public.erp_supplier_respond), what the order's
 * page reads (public.erp_purchase_order_confirmation), and the list of orders
 * still waiting (public.erp_awaiting_confirmations).
 */

export type ConfirmationStatus =
  "awaiting" | "confirmed" | "changes_proposed" | "declined" | "withdrawn";

export type SupplierLine = {
  lineId: string;
  lineNo: number;
  description: string;
  supplierItemCode: string | null;
  quantity: number;
  uom: string;
  unitPriceMinor: number | null;
  requiredDate: string | null;
  confirmedQuantity: number | null;
  confirmedDate: string | null;
  /** What no notice still coming holds (20261005000000). */
  openToNotify: number;
};

/** A notice the supplier sent, as their page shows it (20261005000000). */
export type SupplierNotice = {
  notice: string;
  status: string;
  shipDate: string | null;
  expectedArrival: string | null;
  carrier: string | null;
  trackingReference: string | null;
};

export type SupplierOrder = {
  order: string;
  organisation: string;
  supplier: string;
  currency: string;
  orderDate: string | null;
  status: ConfirmationStatus;
  canRespond: boolean;
  /** Confirmed and still open: the supplier may say what is on its way. */
  canNotify: boolean;
  notices: SupplierNotice[];
  supplierReference: string | null;
  note: string | null;
  /** The buyer's note when they asked again. */
  decisionNote: string | null;
  lines: SupplierLine[];
};

export type ProposedChange = {
  lineId: string;
  lineNo: number;
  orderedQuantity: number;
  quantity: number;
  requiredDate: string | null;
  date: string | null;
};

export type OrderConfirmation = {
  orderId: string;
  order: string;
  state: string;
  status: ConfirmationStatus;
  awaitingSince: string | null;
  respondedAt: string | null;
  respondedVia: "supplier" | "buyer" | null;
  supplierReference: string | null;
  note: string | null;
  proposal: ProposedChange[];
  decisionNote: string | null;
  receivedAny: boolean;
  lines: {
    lineId: string;
    lineNo: number;
    description: string;
    quantity: number;
    requiredDate: string | null;
    confirmedQuantity: number | null;
    confirmedDate: string | null;
  }[];
  mayRecord: boolean;
  mayCancel: boolean;
};

export type AwaitingOrder = {
  orderId: string;
  order: string;
  supplier: string;
  status: ConfirmationStatus;
  daysWaiting: number;
  overdue: boolean;
};

/** What a supplier changes on one line; empty fields mean "as ordered". */
export type LineEdit = { quantity: string; date: string };

/** The answer erp_supplier_respond and erp_record_supplier_confirmation take. */
export type SupplierAnswer = {
  decision: "confirm" | "decline";
  /**
   * Said to come with changes (20261007020000, J-62): the database refuses it
   * when no line is changed, rather than take it as the order as it stands.
   */
  with_changes?: true;
  supplier_reference?: string;
  note?: string;
  lines?: { line_id: string; quantity?: number; date?: string }[];
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

const STATUSES: readonly ConfirmationStatus[] = [
  "awaiting",
  "confirmed",
  "changes_proposed",
  "declined",
  "withdrawn",
];

const status = (v: unknown): ConfirmationStatus =>
  (STATUSES as readonly unknown[]).includes(v) ? (v as ConfirmationStatus) : "awaiting";

const list = (v: unknown): Row[] =>
  (Array.isArray(v) ? v : []).map(asRecord).filter((r): r is Row => r !== null);

/** The order a supplier's link names, or null when the link names none. */
export function supplierOrder(result: unknown): SupplierOrder | null {
  const r = asRecord(result);
  const order = text(r?.["order"]);
  if (r === null || order === null) return null;
  return {
    order,
    organisation: text(r["organisation"]) ?? "Your customer",
    supplier: text(r["supplier"]) ?? "",
    currency: text(r["currency"]) ?? "GBP",
    orderDate: text(r["order_date"]),
    status: status(r["status"]),
    canRespond: r["can_respond"] === true,
    canNotify: r["can_notify"] === true,
    notices: list(r["notices"]).map((n) => ({
      notice: text(n["notice"]) ?? "",
      status: text(n["status"]) ?? "notified",
      shipDate: text(n["ship_date"]),
      expectedArrival: text(n["expected_arrival"]),
      carrier: text(n["carrier"]),
      trackingReference: text(n["tracking_reference"]),
    })),
    supplierReference: text(r["supplier_reference"]),
    note: text(r["note"]),
    decisionNote: text(r["decision_note"]),
    lines: list(r["lines"])
      .map((l) => ({
        lineId: text(l["line_id"]) ?? "",
        lineNo: num(l["line_no"]) ?? 0,
        description: text(l["description"]) ?? text(l["item_code"]) ?? "",
        supplierItemCode: text(l["supplier_item_code"]),
        quantity: num(l["quantity"]) ?? 0,
        uom: text(l["uom"]) ?? "",
        unitPriceMinor: num(l["unit_price_minor"]),
        requiredDate: text(l["required_date"]),
        confirmedQuantity: num(l["confirmed_quantity"]),
        confirmedDate: text(l["confirmed_date"]),
        openToNotify: num(l["open_to_notify"]) ?? 0,
      }))
      .filter((l) => l.lineId !== ""),
  };
}

/**
 * The supplier's answer from the page: confirm, sending only the lines whose
 * quantity or date was changed, or decline with a reason.
 */
export function supplierAnswer(
  order: Pick<SupplierOrder, "lines">,
  decision: "confirm" | "decline",
  edits: Readonly<Record<string, LineEdit>>,
  reference: string,
  note: string,
): SupplierAnswer {
  const answer: SupplierAnswer = { decision };
  if (reference.trim() !== "") answer.supplier_reference = reference.trim();
  if (note.trim() !== "") answer.note = note.trim();
  if (decision === "decline") return answer;
  const lines: NonNullable<SupplierAnswer["lines"]> = [];
  for (const line of order.lines) {
    const edit = edits[line.lineId];
    if (!edit) continue;
    const quantity = edit.quantity.trim() === "" ? null : Number(edit.quantity);
    const date = edit.date.trim() === "" ? null : edit.date.trim();
    const changedQuantity =
      quantity !== null && Number.isFinite(quantity) && quantity !== line.quantity;
    const changedDate = date !== null && date !== line.requiredDate;
    if (!changedQuantity && !changedDate) continue;
    lines.push({
      line_id: line.lineId,
      ...(changedQuantity && quantity !== null ? { quantity } : {}),
      ...(changedDate && date !== null ? { date } : {}),
    });
  }
  if (lines.length > 0) answer.lines = lines;
  return answer;
}

/**
 * The answer a buyer records for the supplier, from the form on the order's
 * page: "They will send it", "They will send it, with changes" or "They cannot
 * take it", each line they changed, their reference and what they said. With
 * changes is a confirmation that names it (J-62); the door is the same.
 */
export function recordedAnswer(
  values: Readonly<Record<string, string>>,
  rows: readonly Readonly<Record<string, string>>[],
): SupplierAnswer {
  const choice = values["decision"] ?? "confirm";
  const answer: SupplierAnswer = { decision: choice === "decline" ? "decline" : "confirm" };
  if (choice === "with_changes") answer.with_changes = true;
  const reference = (values["supplier_reference"] ?? "").trim();
  const note = (values["note"] ?? "").trim();
  if (reference !== "") answer.supplier_reference = reference;
  if (note !== "") answer.note = note;
  // What was typed: the quantities arrive as text.
  const lines = rows
    .filter((row) => (row["line_id"] ?? "") !== "")
    .map((row) => ({
      line_id: row["line_id"] ?? "",
      ...((row["quantity"] ?? "") !== "" ? { quantity: Number(row["quantity"]) } : {}),
      ...(row["date"] ? { date: row["date"] } : {}),
    }));
  if (lines.length > 0) answer.lines = lines;
  return answer;
}

/**
 * Where the supplier's proposal shows on the order's page: to be decided while
 * it waits, and kept once accepted, so what was ordered before the change is
 * still to be read beside what they could send (J-62). An answer given again
 * replaces it, so an accepted one is the last the order had.
 */
export function proposalShown(
  c: Pick<OrderConfirmation, "status" | "proposal">,
): "to_decide" | "accepted" | null {
  if (c.proposal.length === 0) return null;
  if (c.status === "changes_proposed") return "to_decide";
  if (c.status === "confirmed") return "accepted";
  return null;
}

/** A sent order's answer, as its page reads it, or null when it has none. */
export function orderConfirmation(result: unknown): OrderConfirmation | null {
  const r = asRecord(result);
  const orderId = text(r?.["order_id"]);
  if (r === null || orderId === null) return null;
  const via = r["responded_via"];
  return {
    orderId,
    order: text(r["order"]) ?? "",
    state: text(r["state"]) ?? "",
    status: status(r["status"]),
    awaitingSince: text(r["awaiting_since"]),
    respondedAt: text(r["responded_at"]),
    respondedVia: via === "supplier" || via === "buyer" ? via : null,
    supplierReference: text(r["supplier_reference"]),
    note: text(r["note"]),
    proposal: list(r["proposal"]).map((p) => ({
      lineId: text(p["line_id"]) ?? "",
      lineNo: num(p["line_no"]) ?? 0,
      orderedQuantity: num(p["ordered_quantity"]) ?? 0,
      quantity: num(p["quantity"]) ?? 0,
      requiredDate: text(p["required_date"]),
      date: text(p["date"]),
    })),
    decisionNote: text(r["decision_note"]),
    receivedAny: r["received_any"] === true,
    lines: list(r["lines"]).map((l) => ({
      lineId: text(l["line_id"]) ?? "",
      lineNo: num(l["line_no"]) ?? 0,
      description: text(l["description"]) ?? "",
      quantity: num(l["quantity"]) ?? 0,
      requiredDate: text(l["required_date"]),
      confirmedQuantity: num(l["confirmed_quantity"]),
      confirmedDate: text(l["confirmed_date"]),
    })),
    mayRecord: r["may_record"] === true,
    mayCancel: r["may_cancel"] === true,
  };
}

/** The orders still waiting on their supplier, as the database ordered them. */
export function awaitingOrders(result: unknown): AwaitingOrder[] {
  return list(result)
    .map((r) => ({
      orderId: text(r["order_id"]) ?? "",
      order: text(r["order"]) ?? "",
      supplier: text(r["supplier"]) ?? "",
      status: status(r["status"]),
      daysWaiting: num(r["days_waiting"]) ?? 0,
      overdue: r["overdue"] === true,
    }))
    .filter((o) => o.orderId !== "");
}

/** A status in the words a person reads, and how it should look. */
export function confirmationWords(s: ConfirmationStatus): {
  words: string;
  tone: "ok" | "warn" | "bad" | "muted";
} {
  switch (s) {
    case "confirmed":
      return { words: "Confirmed", tone: "ok" };
    case "changes_proposed":
      return { words: "Changes proposed", tone: "warn" };
    case "declined":
      return { words: "Declined", tone: "bad" };
    case "withdrawn":
      return { words: "Withdrawn", tone: "muted" };
    default:
      return { words: "Awaiting confirmation", tone: "muted" };
  }
}

/** The token a supplier's link carries in its fragment, or null. */
export function tokenFromFragment(hash: string): string | null {
  const token = new URLSearchParams(hash.replace(/^#/, "")).get("t");
  return token !== null && /^[0-9a-f]{64}$/.test(token) ? token : null;
}
