/**
 * The organisation's carrier account and a shipment's tracking, as the
 * database answers them (20261004965000): public.erp_carrier_account and
 * public.erp_shipment_tracking. Neither ever carries a key.
 */

/** A document a shipment carries: a collection's order, an outbound shipment's deliveries. */
export type Carried = { documentId: string; documentNumber: string };

export type CarrierAccount = {
  provider: string;
  connected: boolean;
  mode: "test" | "live" | null;
  tracking: boolean;
  connectedAt: string | null;
  webhookPath: string | null;
  mayConnect: boolean;
};

export type ShipmentTracking = {
  shipmentId: string;
  direction: "inbound" | "outbound";
  trackingReference: string | null;
  status: string | null;
  statusAt: string | null;
  detail: string | null;
  labelUrl: string | null;
  labelRateMinor: number | null;
  currency: string | null;
  provider: string | null;
  labelCommandStatus: string | null;
  /** Grams, as weighed or as its items weigh; null when nothing says. */
  weightG: number | null;
  /** As it was booked (J-66, 20261007060000): the carrier's name, null until one is booked. */
  carrier: string | null;
  serviceCode: string | null;
  /** The freight cost booked, in minor units of currency. */
  costMinor: number | null;
  expectedArrival: string | null;
  carries: Carried[];
};

type Row = Record<string, unknown>;

const asRecord = (v: unknown): Row | null =>
  typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Row) : null;

const text = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);

/** The account read, or null when the answer is not one. */
export function carrierAccount(result: unknown): CarrierAccount | null {
  const r = asRecord(result);
  const provider = text(r?.["provider"]);
  if (r === null || provider === null) return null;
  const mode = r["mode"];
  return {
    provider,
    connected: r["connected"] === true,
    mode: mode === "test" || mode === "live" ? mode : null,
    tracking: r["tracking"] === true,
    connectedAt: text(r["connected_at"]),
    webhookPath: text(r["webhook_path"]),
    mayConnect: r["may_connect"] === true,
  };
}

/** The address EasyPost posts tracking to: the project's functions host and the path. */
export function webhookAddress(supabaseUrl: string, path: string | null): string | null {
  if (path === null) return null;
  return `${supabaseUrl.replace(/\/+$/, "")}${path.startsWith("/") ? "" : "/"}${path}`;
}

const grams = (v: unknown): number | null => {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" ? Number(v) : NaN;
  return Number.isFinite(n) && n > 0 ? n : null;
};

/** A shipment's carrier side, or null when the answer is not one. */
export function shipmentTracking(result: unknown): ShipmentTracking | null {
  const r = asRecord(result);
  const shipmentId = text(r?.["shipment_id"]);
  if (r === null || shipmentId === null) return null;
  const rate = r["label_rate_minor"];
  return {
    shipmentId,
    direction: r["direction"] === "inbound" ? "inbound" : "outbound",
    trackingReference: text(r["tracking_reference"]),
    status: text(r["tracking_status"]),
    statusAt: text(r["tracking_status_at"]),
    detail: text(r["tracking_detail"]),
    labelUrl: text(r["label_url"]),
    labelRateMinor: typeof rate === "number" ? rate : null,
    currency: text(r["currency"]),
    provider: text(r["provider"]),
    labelCommandStatus: text(r["label_command_status"]),
    weightG: grams(r["weight_g"]),
    carrier: text(r["carrier"]),
    serviceCode: text(r["service_code"]),
    costMinor: typeof r["cost_minor"] === "number" ? r["cost_minor"] : null,
    expectedArrival: text(r["expected_arrival"]),
    carries: (Array.isArray(r["carries"]) ? (r["carries"] as unknown[]) : []).flatMap((c) => {
      const x = asRecord(c);
      const documentId = text(x?.["document_id"]);
      const documentNumber = text(x?.["document_number"]);
      return documentId !== null && documentNumber !== null ? [{ documentId, documentNumber }] : [];
    }),
  };
}

/** A carrier status in the words a person reads, and how it should look. */
export function trackingWords(status: string | null): {
  words: string;
  tone: "ok" | "warn" | "bad" | "muted";
} {
  switch (status) {
    case "pre_transit":
      return { words: "Label printed", tone: "muted" };
    case "in_transit":
      return { words: "In transit", tone: "muted" };
    case "out_for_delivery":
      return { words: "Out for delivery", tone: "warn" };
    case "available_for_pickup":
      return { words: "Ready to collect", tone: "warn" };
    case "delivered":
      return { words: "Delivered", tone: "ok" };
    case "return_to_sender":
      return { words: "Returning to sender", tone: "bad" };
    case "failure":
    case "error":
      return { words: "Delivery failed", tone: "bad" };
    case "cancelled":
      return { words: "Cancelled", tone: "bad" };
    default:
      return { words: "Not yet tracked", tone: "muted" };
  }
}
