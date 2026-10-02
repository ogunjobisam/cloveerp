/**
 * EasyPost, the carrier aggregator an organisation books through with its own
 * account (20261004965000): buying a shipment's label, and reading what its
 * webhook says afterwards.
 *
 * No database, no environment and no network of its own: the dispatch worker
 * (worker/src/core/carrier.ts) hands in the claimed shipment.buy command, the
 * organisation's key and a fetch, and the carrier webhook
 * (supabase/functions/carrier_webhook) hands in the raw body, its signature
 * header and the organisation's signing secret. Imports nothing, so Deno can
 * follow it and bun can test it, as src/lib/email/resend-webhook.ts does.
 *
 * Buying is two requests: create the shipment, whose answer carries the rates
 * the carrier offers, then buy one. The rate bought is the one for the service
 * the booking named, at the carrier account the carrier is linked to; failing
 * that, the cheapest the account offers. A shipment with no weight, or an
 * address with no street, postcode or country, is refused before anything
 * leaves: the carrier would bill a guess.
 */

export const EASYPOST_API = "https://api.easypost.com/v2";

/** The shipment.buy payload, as erp.request_carrier_label() queued it. */
export type LabelRequest = {
  shipment_id: string;
  reference: string;
  direction: string | null;
  from_address: CarrierAddress;
  to_address: CarrierAddress;
  parcel: { weight_g?: number | string | null };
  carrier_account: string | null;
  service: string | null;
};

export type CarrierAddress = {
  name?: string | null;
  company?: string | null;
  street1?: string | null;
  street2?: string | null;
  city?: string | null;
  state?: string | null;
  zip?: string | null;
  country?: string | null;
};

/** What erp.apply_carrier_label() keeps. */
export type BoughtLabel = {
  tracking_code: string;
  label_url: string | null;
  carrier_shipment_id: string;
  rate_minor: number | null;
  currency: string | null;
};

/** A request that can never succeed: the command is failed, not retried. */
export class LabelRefused extends Error {
  constructor(
    message: string,
    readonly status: number | null = null,
  ) {
    super(message);
    this.name = "LabelRefused";
  }
}

/** A request that may succeed later: a 5xx, a 429, or no answer at all. */
export class LabelUnavailable extends Error {
  constructor(
    message: string,
    readonly answered: boolean,
  ) {
    super(message);
    this.name = "LabelUnavailable";
  }
}

type Row = Record<string, unknown>;
type Fetch = (input: string, init: RequestInit) => Promise<Response>;

const asRecord = (v: unknown): Row | null =>
  typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Row) : null;

const text = (v: unknown): string | null =>
  typeof v === "string" && v.trim() !== "" ? v.trim() : null;

/** Grams to the ounces EasyPost weighs in, to a tenth. */
export function ouncesOf(grams: number): number {
  return Math.max(0.1, Math.round((grams / 28.349523125) * 10) / 10);
}

/** Pounds and pence: a decimal rate as minor units. */
export function minorOf(rate: unknown): number | null {
  const s = typeof rate === "number" ? String(rate) : text(rate);
  if (s === null || !/^\d+(\.\d{1,2})?$/.test(s)) return null;
  const [whole, frac = ""] = s.split(".");
  return Number(whole) * 100 + Number(frac.padEnd(2, "0"));
}

/** What is missing from an address for a carrier to deliver to it, or null. */
export function addressProblem(label: string, a: CarrierAddress | null | undefined): string | null {
  const missing = (["street1", "zip", "country"] as const).filter((k) => text(a?.[k]) === null);
  return missing.length === 0 ? null : `the ${label} address has no ${missing.join(", ")}`;
}

function easypostAddress(a: CarrierAddress): Row {
  const out: Row = {};
  for (const k of [
    "name",
    "company",
    "street1",
    "street2",
    "city",
    "state",
    "zip",
    "country",
  ] as const) {
    const v = text(a[k]);
    if (v !== null) out[k] = v;
  }
  return out;
}

/** The body that creates the shipment at EasyPost. Throws LabelRefused for what cannot be sent. */
export function shipmentBody(req: LabelRequest): Row {
  const grams = Number(req.parcel?.weight_g ?? 0);
  if (!Number.isFinite(grams) || grams <= 0) {
    throw new LabelRefused(
      `shipment ${req.reference} has no weight, so no carrier can price it; record its weight and book again`,
    );
  }
  const problem =
    addressProblem("sender's", req.from_address) ?? addressProblem("recipient's", req.to_address);
  if (problem !== null) throw new LabelRefused(`shipment ${req.reference}: ${problem}`);
  return {
    shipment: {
      reference: req.reference,
      from_address: easypostAddress(req.from_address),
      to_address: easypostAddress(req.to_address),
      parcel: { weight: ouncesOf(grams) },
      ...(text(req.carrier_account) ? { carrier_accounts: [text(req.carrier_account)] } : {}),
      options: { label_format: "PDF" },
    },
  };
}

export type Rate = {
  id: string;
  service: string | null;
  carrierAccount: string | null;
  minor: number | null;
  currency: string | null;
};

/** The rates a created shipment offers. */
export function ratesOf(shipment: unknown): Rate[] {
  const rows = asRecord(shipment)?.["rates"];
  return (Array.isArray(rows) ? rows : [])
    .map(asRecord)
    .filter((r): r is Row => r !== null && text(r["id"]) !== null)
    .map((r) => ({
      id: text(r["id"]) as string,
      service: text(r["service"]),
      carrierAccount: text(r["carrier_account_id"]),
      minor: minorOf(r["rate"]),
      currency: text(r["currency"]),
    }));
}

/**
 * The rate to buy: the booked service at the linked account, or the cheapest
 * the account offers, or null when it offers nothing.
 */
export function chooseRate(
  rates: Rate[],
  service: string | null,
  account: string | null,
): Rate | null {
  const atAccount = account === null ? rates : rates.filter((r) => r.carrierAccount === account);
  const wanted = service?.toLowerCase() ?? null;
  const named =
    wanted === null ? undefined : atAccount.find((r) => r.service?.toLowerCase() === wanted);
  if (named) return named;
  const priced = atAccount.filter((r) => r.minor !== null);
  if (priced.length === 0) return atAccount[0] ?? null;
  return priced.reduce((a, b) => ((b.minor as number) < (a.minor as number) ? b : a));
}

/** What a bought shipment answers, as erp.apply_carrier_label() reads it. */
export function boughtLabel(shipment: unknown): BoughtLabel {
  const s = asRecord(shipment);
  const tracking = text(s?.["tracking_code"]);
  const id = text(s?.["id"]);
  if (s === null || tracking === null || id === null) {
    throw new LabelRefused("EasyPost bought the label but answered without a tracking code");
  }
  const selected = asRecord(s["selected_rate"]);
  return {
    tracking_code: tracking,
    label_url:
      text(asRecord(s["postage_label"])?.["label_pdf_url"]) ??
      text(asRecord(s["postage_label"])?.["label_url"]),
    carrier_shipment_id: id,
    rate_minor: minorOf(selected?.["rate"]),
    currency: text(selected?.["currency"]),
  };
}

function authorization(apiKey: string): string {
  return `Basic ${btoa(`${apiKey}:`)}`;
}

async function call(
  fetcher: Fetch,
  apiKey: string,
  path: string,
  body: Row,
  timeoutMs: number,
): Promise<unknown> {
  let response: Response;
  try {
    response = await fetcher(`${EASYPOST_API}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: authorization(apiKey) },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (err) {
    throw new LabelUnavailable(
      `EasyPost gave no answer within ${timeoutMs} ms: ${(err as Error).name}`,
      false,
    );
  }
  if (!response.ok) {
    // The status and a bounded slice of the body; never the request, which
    // carries the key.
    const detail = (await response.text()).slice(0, 400);
    const message = `EasyPost answered ${response.status} to ${path}: ${detail}`;
    if (response.status >= 400 && response.status < 500 && response.status !== 429) {
      throw new LabelRefused(message, response.status);
    }
    throw new LabelUnavailable(message, true);
  }
  return response.json();
}

/** Create the shipment, choose its rate and buy it. */
export async function buyLabel(
  req: LabelRequest,
  apiKey: string,
  deps: { fetch?: Fetch; timeoutMs?: number } = {},
): Promise<BoughtLabel> {
  const fetcher = deps.fetch ?? ((input, init) => fetch(input, init));
  const timeoutMs = deps.timeoutMs ?? 20_000;
  const created = await call(fetcher, apiKey, "/shipments", shipmentBody(req), timeoutMs);
  const id = text(asRecord(created)?.["id"]);
  if (id === null)
    throw new LabelRefused("EasyPost created the shipment but answered without its id");
  const rate = chooseRate(ratesOf(created), text(req.service), text(req.carrier_account));
  if (rate === null) {
    throw new LabelRefused(
      `EasyPost offered no rate for shipment ${req.reference}${req.carrier_account ? ` at carrier account ${req.carrier_account}` : ""}`,
    );
  }
  const bought = await call(
    fetcher,
    apiKey,
    `/shipments/${encodeURIComponent(id)}/buy`,
    { rate: { id: rate.id } },
    timeoutMs,
  );
  return boughtLabel(bought);
}

// ---------------------------------------------------------------------------
// The webhook
// ---------------------------------------------------------------------------

/** EasyPost's signature header: hmac-sha256-hex= and the HMAC of the body. */
export const SIGNATURE_HEADER = "x-hmac-signature";

function hex(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** The signature EasyPost would send for this body under this secret. */
export async function webhookSignature(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret.normalize("NFKD")),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return `hmac-sha256-hex=${hex(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body)))}`;
}

function sameText(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Whether the body is EasyPost's, signed with this secret. */
export async function verifyCarrierWebhook(input: {
  body: string;
  signature: string | null | undefined;
  secret: string | null | undefined;
}): Promise<{ ok: true } | { ok: false; reason: string }> {
  const secret = input.secret?.trim() ?? "";
  if (secret === "") return { ok: false, reason: "the organisation has no webhook signing secret" };
  const given = input.signature?.trim().toLowerCase() ?? "";
  if (given === "") return { ok: false, reason: "the request is not signed" };
  const expected = await webhookSignature(secret, input.body);
  return sameText(given, expected)
    ? { ok: true }
    : { ok: false, reason: "the signature does not match the body" };
}

export type TrackingEvent = {
  eventId: string;
  trackingCode: string;
  status: string;
  occurredAt: string | null;
  detail: string | null;
};

/** A tracker event's status, as erp.record_carrier_tracking() knows them. */
export const TRACKING_STATUSES = [
  "unknown",
  "pre_transit",
  "in_transit",
  "out_for_delivery",
  "available_for_pickup",
  "delivered",
  "return_to_sender",
  "failure",
  "cancelled",
  "error",
] as const;

/** A tracker.created or tracker.updated event, or null for anything else. */
export function parseTrackingEvent(body: string): TrackingEvent | null {
  let raw: unknown;
  try {
    raw = JSON.parse(body);
  } catch {
    return null;
  }
  const e = asRecord(raw);
  const kind = text(e?.["description"]);
  if (e === null || (kind !== "tracker.created" && kind !== "tracker.updated")) return null;
  const result = asRecord(e["result"]);
  const eventId = text(e["id"]);
  const trackingCode = text(result?.["tracking_code"]);
  const status = text(result?.["status"]);
  if (eventId === null || trackingCode === null || status === null) return null;
  const details = result?.["tracking_details"];
  const last = Array.isArray(details) ? asRecord(details[details.length - 1]) : null;
  return {
    eventId,
    trackingCode,
    status: (TRACKING_STATUSES as readonly string[]).includes(status) ? status : "unknown",
    occurredAt: text(last?.["datetime"]) ?? text(result?.["updated_at"]),
    detail: text(last?.["message"]) ?? text(result?.["status_detail"]),
  };
}
