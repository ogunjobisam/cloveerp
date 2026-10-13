/**
 * Making Tax Digital for VAT: what is said to HMRC and how its answers are
 * read (HMRC MTD, 13 October 2026).
 *
 * Pure and import-free, so the Edge Function that talks to HMRC
 * (supabase/functions/hmrc) and the browser that collects the fraud
 * prevention data share one statement of it, and Bun tests it against the
 * examples in HMRC's own VAT API specification without a sandbox account.
 * Nothing here holds a secret: the client secret and the tokens live in the
 * function's environment and the client's Vault.
 */

export type HmrcEnvironment = "sandbox" | "production";

/** HMRC's API host for an environment. Sandbox unless production is said. */
export function apiBase(environment: HmrcEnvironment): string {
  return environment === "production"
    ? "https://api.service.hmrc.gov.uk"
    : "https://test-api.service.hmrc.gov.uk";
}

export function environmentOf(value: string | null | undefined): HmrcEnvironment {
  return value === "production" ? "production" : "sandbox";
}

/** The one redirect URI registered with HMRC: a relay on the apex. */
export const CALLBACK_PATH = "/hmrc/callback";

export const SCOPES = ["read:vat", "write:vat"] as const;

/** The Accept header every VAT API call carries. */
export const ACCEPT = "application/vnd.hmrc.1.0+json";

/** A VAT registration number as HMRC takes it: nine digits, no prefix or spaces. */
export function normaliseVrn(raw: string | null | undefined): string | null {
  const digits = (raw ?? "").toUpperCase().replace(/^GB/, "").replace(/\s+/g, "");
  return /^\d{9}$/.test(digits) ? digits : null;
}

export function authoriseUrl(args: {
  environment: HmrcEnvironment;
  clientId: string;
  redirectUri: string;
  state: string;
}): string {
  const q = new URLSearchParams({
    response_type: "code",
    client_id: args.clientId,
    scope: SCOPES.join(" "),
    state: args.state,
    redirect_uri: args.redirectUri,
  });
  return `${apiBase(args.environment)}/oauth/authorize?${q.toString()}`;
}

// ── The state that travels through HMRC and back ───────────────────────────
//
// The ticket the database opened, the client host the relay returns to, and
// an HMAC over both under the function's secret. The relay on the apex reads
// the host to know where to send the person; only the function, holding the
// key, trusts the ticket.

function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64url(text: string): Uint8Array {
  const padded = text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4);
  const raw = atob(padded);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

async function hmac(key: string, payload: string): Promise<string> {
  const k = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(payload));
  return base64url(new Uint8Array(sig));
}

export async function signState(key: string, ticket: string, host: string): Promise<string> {
  const payload = base64url(new TextEncoder().encode(JSON.stringify({ t: ticket, h: host })));
  return `${payload}.${await hmac(key, payload)}`;
}

/** The host a state names, unverified: the relay's only need. */
export function stateHost(state: string): string | null {
  const [payload] = state.split(".");
  if (!payload) return null;
  try {
    const parsed = JSON.parse(new TextDecoder().decode(fromBase64url(payload))) as { h?: unknown };
    return typeof parsed.h === "string" ? parsed.h : null;
  } catch {
    return null;
  }
}

/** The ticket a state carries, when its signature holds; null otherwise. */
export async function verifyState(
  key: string,
  state: string,
): Promise<{ ticket: string; host: string } | null> {
  const [payload, sig, extra] = state.split(".");
  if (!payload || !sig || extra !== undefined) return null;
  const expected = await hmac(key, payload);
  if (expected.length !== sig.length) return null;
  let diff = 0;
  for (let i = 0; i < sig.length; i++) diff |= expected.charCodeAt(i) ^ sig.charCodeAt(i);
  if (diff !== 0) return null;
  try {
    const parsed = JSON.parse(new TextDecoder().decode(fromBase64url(payload))) as {
      t?: unknown;
      h?: unknown;
    };
    return typeof parsed.t === "string" && typeof parsed.h === "string"
      ? { ticket: parsed.t, host: parsed.h }
      : null;
  } catch {
    return null;
  }
}

/**
 * Where the relay may send a person back to: the apex, or one label under it.
 * Anything else is refused, so the relay is never an open redirect.
 */
export function relayTarget(host: string | null, apex: string): string | null {
  if (!host) return null;
  const h = host.toLowerCase();
  const a = apex.toLowerCase();
  if (h === a || h === `www.${a}`) return h;
  const label = h.endsWith(`.${a}`) ? h.slice(0, -a.length - 1) : null;
  return label && /^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$/.test(label) ? h : null;
}

// ── Obligations ────────────────────────────────────────────────────────────

export type Obligation = {
  periodKey: string;
  start: string;
  end: string;
  due: string;
  status: "O" | "F";
  received?: string;
};

export function readObligations(json: unknown): Obligation[] {
  const list = (json as { obligations?: unknown } | null)?.obligations;
  if (!Array.isArray(list)) return [];
  return list.flatMap((o): Obligation[] => {
    const x = o as Record<string, unknown>;
    const periodKey = x["periodKey"];
    const start = x["start"];
    const end = x["end"];
    const due = x["due"];
    const status = x["status"];
    if (
      typeof periodKey !== "string" ||
      typeof start !== "string" ||
      typeof end !== "string" ||
      typeof due !== "string" ||
      (status !== "O" && status !== "F")
    ) {
      return [];
    }
    const received = x["received"];
    return [
      {
        periodKey,
        start,
        end,
        due,
        status,
        ...(typeof received === "string" ? { received } : {}),
      },
    ];
  });
}

/** The open obligation a return for these dates answers, or null. */
export function obligationFor(list: Obligation[], start: string, end: string): Obligation | null {
  return list.find((o) => o.status === "O" && o.start === start && o.end === end) ?? null;
}

// ── The return ─────────────────────────────────────────────────────────────

const RETURN_FIELDS = [
  "vatDueSales",
  "vatDueAcquisitions",
  "totalVatDue",
  "vatReclaimedCurrPeriod",
  "netVatDue",
  "totalValueSalesExVAT",
  "totalValuePurchasesExVAT",
  "totalValueGoodsSuppliedExVAT",
  "totalAcquisitionsExVAT",
] as const;

/**
 * The body HMRC takes, from the finalised return's MTD export
 * (erp.vat_return_export, format json): its nine boxes, the period key HMRC
 * gave the obligation, and finalised true. The export's own vrn and period
 * dates are for the file and are not sent.
 */
export function returnBody(exported: Record<string, unknown>, periodKey: string): Record<string, unknown> {
  const body: Record<string, unknown> = { periodKey };
  for (const f of RETURN_FIELDS) {
    const v = exported[f];
    if (typeof v !== "number" && typeof v !== "string") {
      throw new Error(`the return's ${f} is missing`);
    }
    body[f] = typeof v === "string" ? Number(v) : v;
  }
  body["finalised"] = true;
  return body;
}

export type Receipt = {
  processingDate: string;
  formBundleNumber: string;
  paymentIndicator: string | null;
  chargeRefNumber: string | null;
  receiptId: string | null;
  receiptTimestamp: string | null;
  correlationId: string | null;
};

/** HMRC's answer to a submission, from its body and headers. */
export function readReceipt(json: unknown, headers: { get(name: string): string | null }): Receipt {
  const x = (json ?? {}) as Record<string, unknown>;
  const processingDate = x["processingDate"];
  const formBundleNumber = x["formBundleNumber"];
  if (typeof processingDate !== "string" || typeof formBundleNumber !== "string") {
    throw new Error("HMRC accepted the return but its receipt names no processing date or form bundle");
  }
  const s = (k: string) => (typeof x[k] === "string" ? (x[k] as string) : null);
  return {
    processingDate,
    formBundleNumber,
    paymentIndicator: s("paymentIndicator"),
    chargeRefNumber: s("chargeRefNumber"),
    receiptId: headers.get("Receipt-ID"),
    receiptTimestamp: headers.get("Receipt-Timestamp"),
    correlationId: headers.get("X-CorrelationId"),
  };
}

/** HMRC's error, in words a person filing VAT can act on. */
export function hmrcProblem(status: number, json: unknown): { code: string; words: string } {
  const x = (json ?? {}) as Record<string, unknown>;
  const errors = Array.isArray(x["errors"]) ? (x["errors"] as Record<string, unknown>[]) : [];
  const code = String(x["code"] ?? errors[0]?.["code"] ?? `HTTP_${status}`);
  const words: Record<string, string> = {
    DUPLICATE_SUBMISSION: "HMRC already holds a return for this period.",
    TAX_PERIOD_NOT_ENDED: "HMRC says the period has not ended yet.",
    NOT_FINALISED: "HMRC needs the return declared as final.",
    INVALID_REQUEST: "HMRC could not read the return.",
    VRN_INVALID: "HMRC does not recognise the company's VAT number.",
    INVALID_CREDENTIALS: "The connection to HMRC has expired. Connect the company to HMRC again.",
    CLIENT_OR_AGENT_NOT_AUTHORISED: "The person who connected this company to HMRC may not file its VAT.",
    MATCHING_RESOURCE_NOT_FOUND: "HMRC has no record of this.",
    INSOLVENT_TRADER: "HMRC holds this company as an insolvent trader and refuses the return.",
    MESSAGE_THROTTLED_OUT: "HMRC asked us to slow down. Try again in a minute.",
  };
  return { code, words: words[code] ?? `HMRC refused the request (${code}).` };
}

// ── Fraud prevention headers (WEB_APP_VIA_SERVER) ──────────────────────────

/** What the browser can see and HMRC asks for, collected as the person presses. */
export type ClientFacts = {
  deviceId: string;
  userAgent: string;
  screens: { width: number; height: number; scalingFactor: number; colourDepth: number }[];
  window: { width: number; height: number };
  /** Minutes east of UTC, as -Date.getTimezoneOffset() gives it. */
  utcOffsetMinutes: number;
};

/** What only the server sees. Unknowns are left out, never guessed. */
export type ServerFacts = {
  clientPublicIp: string | null;
  clientPublicIpAt: Date;
  vendorPublicIp: string | null;
  userIds: Record<string, string>;
  productName: string;
  versions: Record<string, string>;
};

const enc = (v: string) => encodeURIComponent(v);
const pairs = (o: Record<string, string>) =>
  Object.entries(o)
    .map(([k, v]) => `${enc(k)}=${enc(v)}`)
    .join("&");

export function utcOffset(minutes: number): string {
  const sign = minutes < 0 ? "-" : "+";
  const m = Math.abs(minutes);
  return `UTC${sign}${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
}

/**
 * The headers HMRC requires by law on every VAT API call, for a web
 * application whose server makes the call. A header whose value cannot be
 * collected is left out rather than filled with a placeholder, which HMRC
 * forbids; the ones this leaves out are named in HEADERS_NOT_SENT, to be
 * discussed with HMRC as its guidance requires.
 */
export function fraudHeaders(client: ClientFacts, server: ServerFacts): Record<string, string> {
  const h: Record<string, string> = {
    "Gov-Client-Connection-Method": "WEB_APP_VIA_SERVER",
    "Gov-Client-Browser-JS-User-Agent": client.userAgent,
    "Gov-Client-Device-ID": client.deviceId,
    "Gov-Client-Screens": client.screens
      .map((s) =>
        pairs({
          width: String(Math.round(s.width)),
          height: String(Math.round(s.height)),
          "scaling-factor": String(s.scalingFactor),
          "colour-depth": String(s.colourDepth),
        }),
      )
      .join(","),
    "Gov-Client-Timezone": utcOffset(client.utcOffsetMinutes),
    "Gov-Client-User-IDs": pairs(server.userIds),
    "Gov-Client-Window-Size": pairs({
      width: String(Math.round(client.window.width)),
      height: String(Math.round(client.window.height)),
    }),
    "Gov-Vendor-Product-Name": enc(server.productName),
    "Gov-Vendor-Version": pairs(server.versions),
  };
  if (server.clientPublicIp) {
    h["Gov-Client-Public-IP"] = server.clientPublicIp;
    h["Gov-Client-Public-IP-Timestamp"] = server.clientPublicIpAt.toISOString();
  }
  if (server.vendorPublicIp) h["Gov-Vendor-Public-IP"] = server.vendorPublicIp;
  if (server.vendorPublicIp && server.clientPublicIp) {
    h["Gov-Vendor-Forwarded"] = pairs({ by: server.vendorPublicIp, for: server.clientPublicIp });
  }
  return h;
}

/**
 * Headers left out because nothing in the stack can collect them, each with
 * the reason to give HMRC when the omission is discussed with them.
 */
export const HEADERS_NOT_SENT: Readonly<Record<string, string>> = {
  "Gov-Client-Multi-Factor": "Clove ERP signs people in with a password or an emailed link; there is no second factor to report.",
  "Gov-Client-Public-Port":
    "The request reaches the function through Supabase's edge, which does not pass on the client's source port.",
  "Gov-Vendor-License-IDs": "Clove ERP is sold by subscription; no licence key is installed on the device.",
};

/** The first public address in an X-Forwarded-For chain, as the edge saw the client. */
export function clientIp(forwardedFor: string | null): string | null {
  const first = (forwardedFor ?? "").split(",")[0]?.trim() ?? "";
  if (!first) return null;
  const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(first);
  if (v4) {
    const [a, b] = [Number(v4[1]), Number(v4[2])];
    const isPrivate =
      a === 10 || a === 127 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 169 && b === 254);
    return isPrivate ? null : first;
  }
  return /^[0-9a-f:]+$/i.test(first) && first.includes(":") && !/^(::1|fe80:|fc|fd)/i.test(first) ? first : null;
}

/** HMRC's legal declaration, shown and ticked before a return is submitted. */
export const DECLARATION =
  "When you submit this VAT information you are making a legal declaration that the information is true and complete. A false declaration can result in prosecution.";
