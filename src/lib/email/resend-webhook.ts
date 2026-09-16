/**
 * Resend's webhooks: is this request really Resend's, and what does it say?
 *
 * Resend signs every webhook the way Svix does — three headers, an HMAC over
 * the exact bytes of the body, and a timestamp — and this file is the whole of
 * that check, with no database, no network and no environment. The endpoint
 * that uses it (supabase/functions/resend_webhook) reads the secret from the
 * vault, hands the raw body and the headers here, and does nothing at all
 * until this file says the request is Resend's.
 *
 * Separated from the endpoint because a signature check is exactly the kind of
 * code that must be tested rather than watched: every refusal below is a case
 * in resend-webhook.test.ts, including the ones that matter most — a body
 * altered after signing, a signature for a different id, an old timestamp, and
 * a secret that is not set at all.
 *
 * What is NOT here: the replay check. A replayed id is refused by the database,
 * which is the only thing that knows what it has already seen
 * (erp.record_email_delivery_event()).
 */

/** How old a signed request may be. Svix's own tolerance, and Resend's. */
export const WEBHOOK_TOLERANCE_SECONDS = 300;

/** The three headers Resend sends with every webhook. */
export type WebhookHeaders = {
  id: string | null | undefined;
  timestamp: string | null | undefined;
  signature: string | null | undefined;
};

/** Why a request was refused, in words the endpoint can log without leaking. */
export type WebhookVerdict =
  { ok: true; eventId: string; signedAt: Date } | { ok: false; reason: string };

/** Reads the three headers from a Request, whatever case they arrive in. */
export function webhookHeaders(headers: Headers): WebhookHeaders {
  return {
    id: headers.get("svix-id") ?? headers.get("webhook-id"),
    timestamp: headers.get("svix-timestamp") ?? headers.get("webhook-timestamp"),
    signature: headers.get("svix-signature") ?? headers.get("webhook-signature"),
  };
}

function decodeBase64(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function encodeBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 1) binary += String.fromCharCode(bytes[i] ?? 0);
  return btoa(binary);
}

/**
 * The secret as key material: whsec_ and then base64, which is how it is
 * written in the Resend dashboard and how it is kept in the vault.
 */
export function webhookKeyBytes(secret: string): Uint8Array {
  const value = secret.trim().replace(/^whsec_/, "");
  if (value === "") throw new Error("the webhook signing secret is empty");
  return decodeBase64(value);
}

/** What is signed: the id, the timestamp and the body, exactly as they arrived. */
export function signedContent(id: string, timestamp: string, body: string): string {
  return `${id}.${timestamp}.${body}`;
}

/** The signature Resend would have sent for this content, base64 as it sends it. */
export async function webhookSignature(secret: string, content: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    webhookKeyBytes(secret) as unknown as ArrayBuffer,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signed = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(content));
  return encodeBase64(new Uint8Array(signed));
}

/**
 * Equal or not, in the same time either way: a comparison that stops early
 * tells whoever is guessing how much of their guess was right.
 */
export function sameSignature(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let differences = 0;
  for (let i = 0; i < a.length; i += 1) differences |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return differences === 0;
}

/** The v1 signatures in the header; anything of another version is ignored. */
function offeredSignatures(header: string): string[] {
  return header
    .split(" ")
    .map((part) => part.trim())
    .filter((part) => part.startsWith("v1,"))
    .map((part) => part.slice(3));
}

/**
 * Whether this request is Resend's.
 *
 * Every refusal is a reason rather than a throw, so the endpoint answers the
 * same way (401, nothing recorded) whichever one it is. `body` must be the raw
 * text of the request: a body that has been parsed and re-serialised is a
 * different body, and will not verify.
 */
export async function verifyResendWebhook(args: {
  headers: WebhookHeaders;
  body: string;
  secret: string | null | undefined;
  now?: Date;
  toleranceSeconds?: number;
}): Promise<WebhookVerdict> {
  const secret = (args.secret ?? "").trim();
  if (secret === "") return { ok: false, reason: "no webhook signing secret is set" };

  const id = (args.headers.id ?? "").trim();
  const timestamp = (args.headers.timestamp ?? "").trim();
  const signature = (args.headers.signature ?? "").trim();
  if (id === "" || timestamp === "" || signature === "") {
    return { ok: false, reason: "the request carries no signature headers" };
  }

  const seconds = Number(timestamp);
  if (!Number.isFinite(seconds) || !/^\d+$/.test(timestamp)) {
    return { ok: false, reason: "the signature timestamp is not a time" };
  }
  const tolerance = args.toleranceSeconds ?? WEBHOOK_TOLERANCE_SECONDS;
  const now = args.now ?? new Date();
  const age = now.getTime() / 1000 - seconds;
  if (age > tolerance) return { ok: false, reason: "the request is older than five minutes" };
  if (age < -tolerance) return { ok: false, reason: "the request is signed in the future" };

  const offered = offeredSignatures(signature);
  if (offered.length === 0) return { ok: false, reason: "the signature is of no version we check" };

  let expected: string;
  try {
    expected = await webhookSignature(secret, signedContent(id, timestamp, args.body));
  } catch {
    return { ok: false, reason: "the webhook signing secret is not a secret we can use" };
  }
  if (!offered.some((candidate) => sameSignature(candidate, expected))) {
    return { ok: false, reason: "the signature does not match the body" };
  }
  return { ok: true, eventId: id, signedAt: new Date(seconds * 1000) };
}

/* -------------------------------------------------------------------------- */
/* What the event says                                                        */
/* -------------------------------------------------------------------------- */

/**
 * The states we keep, in the order they may follow one another. The database
 * refuses to move a message backwards along this list, so a "sent" that
 * arrives after its "delivered" changes nothing.
 */
export const DELIVERY_STATES = [
  "sent",
  "delayed",
  "delivered",
  "opened",
  "complained",
  "bounced",
] as const;

export type DeliveryState = (typeof DELIVERY_STATES)[number];

const OF_TYPE: Record<string, DeliveryState> = {
  "email.sent": "sent",
  "email.delivery_delayed": "delayed",
  "email.delivered": "delivered",
  "email.opened": "opened",
  "email.complained": "complained",
  "email.bounced": "bounced",
};

export type ResendEvent = {
  /** The event's own type, as Resend wrote it. */
  type: string;
  /** What it means for the message, or null for an event we keep no state for. */
  state: DeliveryState | null;
  /** Resend's id for the message, which is what we stored when we sent it. */
  providerMessageId: string | null;
  /** When the event happened, as Resend timed it. */
  occurredAt: string | null;
  recipient: string | null;
  /** For a bounce: whether it is permanent, and what the provider said. */
  bounceKind: string | null;
  detail: string | null;
};

function text(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed === "" ? null : trimmed.slice(0, 500);
}

function dict(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

/**
 * The body as an event, or null when it is not one we can read.
 *
 * Resend carries the message id as data.email_id — the id its API returned
 * when we sent the message, and the one on the queue row. data.message_id is
 * the RFC Message-ID header, which is a different thing and not what we store.
 */
export function parseResendEvent(body: string): ResendEvent | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    return null;
  }
  const top = dict(parsed);
  const type = text(top?.["type"]);
  if (!top || !type) return null;
  const data = dict(top["data"]) ?? {};
  const to = data["to"];
  const bounce = dict(data["bounce"]);
  const kind = text(bounce?.["type"]);
  const subType = text(bounce?.["subType"]);
  return {
    type,
    state: OF_TYPE[type] ?? null,
    providerMessageId: text(data["email_id"]),
    occurredAt: text(top["created_at"]) ?? text(data["created_at"]),
    recipient: Array.isArray(to) ? text(to[0]) : text(to),
    bounceKind: kind && subType ? `${kind}/${subType}` : kind,
    detail: text(bounce?.["message"]) ?? text(data["subject"]),
  };
}

/** Whether a bounce is the provider saying "never", rather than "not yet". */
export function isHardBounce(event: Pick<ResendEvent, "state" | "bounceKind">): boolean {
  return (
    event.state === "bounced" && (event.bounceKind ?? "").toLowerCase().startsWith("permanent")
  );
}
