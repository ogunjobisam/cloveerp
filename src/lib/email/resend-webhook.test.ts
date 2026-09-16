import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

import {
  DELIVERY_STATES,
  isHardBounce,
  parseResendEvent,
  sameSignature,
  signedContent,
  verifyResendWebhook,
  webhookHeaders,
  webhookSignature,
  WEBHOOK_TOLERANCE_SECONDS,
} from "./resend-webhook";

const SECRET = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
const ID = "msg_2Qq8YQZ8Z8Z8Z8Z8Z8Z8Z8";
const NOW = new Date("2026-09-16T10:00:00Z");
const STAMP = String(Math.floor(NOW.getTime() / 1000));

const DELIVERED = JSON.stringify({
  type: "email.delivered",
  created_at: "2026-09-16T09:59:58.126Z",
  data: {
    created_at: "2026-09-16T09:59:55.894Z",
    email_id: "56761188-7520-42d8-8898-ff6fc54ce618",
    message_id: "<111-222-333@email.example.com>",
    from: "Clove ERP <billing@cloveerp.com>",
    to: ["accounts@example.com"],
    subject: "Invoice INV-EXAMPLE-202609-001 is due on 28 September 2026",
  },
});

const BOUNCED = JSON.stringify({
  type: "email.bounced",
  created_at: "2026-09-16T09:59:58.126Z",
  data: {
    email_id: "56761188-7520-42d8-8898-ff6fc54ce618",
    from: "Clove ERP <billing@cloveerp.com>",
    to: ["gone@example.com"],
    subject: "Invoice INV-EXAMPLE-202609-001",
    bounce: {
      message: "The recipient's email address is on the suppression list.",
      subType: "Suppressed",
      type: "Permanent",
    },
  },
});

async function signed(body: string, over: { id?: string; timestamp?: string } = {}) {
  const id = over.id ?? ID;
  const timestamp = over.timestamp ?? STAMP;
  const signature = await webhookSignature(SECRET, signedContent(id, timestamp, body));
  return { headers: { id, timestamp, signature: `v1,${signature}` }, body };
}

describe("a request that says it is Resend's", () => {
  test("verifies when it is signed with our secret over the body we were sent", async () => {
    const request = await signed(DELIVERED);
    const verdict = await verifyResendWebhook({ ...request, secret: SECRET, now: NOW });
    expect(verdict).toEqual({ ok: true, eventId: ID, signedAt: new Date(Number(STAMP) * 1000) });
  });

  test("a signature over a different body, id or timestamp does not verify", async () => {
    const request = await signed(DELIVERED);
    const tampered = DELIVERED.replace("delivered", "bounced");
    for (const broken of [
      { ...request, body: tampered },
      { ...request, headers: { ...request.headers, id: "msg_somebody_else" } },
      { ...request, headers: { ...request.headers, timestamp: String(Number(STAMP) - 1) } },
    ]) {
      const verdict = await verifyResendWebhook({ ...broken, secret: SECRET, now: NOW });
      expect(verdict).toEqual({ ok: false, reason: "the signature does not match the body" });
    }
  });

  test("another sender's secret does not verify", async () => {
    const request = await signed(DELIVERED);
    const verdict = await verifyResendWebhook({
      ...request,
      secret: "whsec_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      now: NOW,
    });
    expect(verdict.ok).toBe(false);
  });

  test("an old request and one signed in the future are refused", async () => {
    const request = await signed(DELIVERED);
    const late = new Date(NOW.getTime() + (WEBHOOK_TOLERANCE_SECONDS + 1) * 1000);
    expect(await verifyResendWebhook({ ...request, secret: SECRET, now: late })).toEqual({
      ok: false,
      reason: "the request is older than five minutes",
    });
    const early = new Date(NOW.getTime() - (WEBHOOK_TOLERANCE_SECONDS + 1) * 1000);
    expect(await verifyResendWebhook({ ...request, secret: SECRET, now: early })).toEqual({
      ok: false,
      reason: "the request is signed in the future",
    });
    const edge = new Date(NOW.getTime() + WEBHOOK_TOLERANCE_SECONDS * 1000);
    expect((await verifyResendWebhook({ ...request, secret: SECRET, now: edge })).ok).toBe(true);
  });

  test("no secret, no headers and no v1 signature are each refused in their own words", async () => {
    const request = await signed(DELIVERED);
    expect(await verifyResendWebhook({ ...request, secret: null, now: NOW })).toEqual({
      ok: false,
      reason: "no webhook signing secret is set",
    });
    expect(await verifyResendWebhook({ ...request, secret: "   ", now: NOW })).toEqual({
      ok: false,
      reason: "no webhook signing secret is set",
    });
    expect(
      await verifyResendWebhook({
        ...request,
        headers: { ...request.headers, signature: null },
        secret: SECRET,
        now: NOW,
      }),
    ).toEqual({ ok: false, reason: "the request carries no signature headers" });
    expect(
      await verifyResendWebhook({
        ...request,
        headers: { ...request.headers, timestamp: "yesterday" },
        secret: SECRET,
        now: NOW,
      }),
    ).toEqual({ ok: false, reason: "the signature timestamp is not a time" });
    expect(
      await verifyResendWebhook({
        ...request,
        headers: { ...request.headers, signature: "v9,AAAA" },
        secret: SECRET,
        now: NOW,
      }),
    ).toEqual({ ok: false, reason: "the signature is of no version we check" });
  });

  test("one good signature among several is enough, as Svix rotates them", async () => {
    const request = await signed(DELIVERED);
    const withOthers = {
      ...request,
      headers: {
        ...request.headers,
        signature: `v1,AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= ${request.headers.signature}`,
      },
    };
    expect((await verifyResendWebhook({ ...withOthers, secret: SECRET, now: NOW })).ok).toBe(true);
  });

  test("the headers are read from the request, under either name", () => {
    const headers = new Headers({
      "svix-id": "a",
      "svix-timestamp": "b",
      "svix-signature": "c",
    });
    expect(webhookHeaders(headers)).toEqual({ id: "a", timestamp: "b", signature: "c" });
    expect(webhookHeaders(new Headers({ "webhook-id": "d" })).id).toBe("d");
    expect(webhookHeaders(new Headers()).signature).toBeNull();
  });

  test("comparing signatures does not stop at the first difference", () => {
    expect(sameSignature("abcd", "abcd")).toBe(true);
    expect(sameSignature("abcd", "abce")).toBe(false);
    expect(sameSignature("abcd", "abc")).toBe(false);
  });
});

describe("what the event says", () => {
  test("a delivery names the message we sent, the recipient and the time", () => {
    const event = parseResendEvent(DELIVERED);
    expect(event).toMatchObject({
      type: "email.delivered",
      state: "delivered",
      providerMessageId: "56761188-7520-42d8-8898-ff6fc54ce618",
      occurredAt: "2026-09-16T09:59:58.126Z",
      recipient: "accounts@example.com",
      bounceKind: null,
    });
  });

  test("a bounce carries whether it is permanent and what the provider said", () => {
    const event = parseResendEvent(BOUNCED);
    expect(event?.state).toBe("bounced");
    expect(event?.bounceKind).toBe("Permanent/Suppressed");
    expect(event?.detail).toBe("The recipient's email address is on the suppression list.");
    expect(isHardBounce(event!)).toBe(true);
    expect(isHardBounce({ state: "bounced", bounceKind: "Transient/General" })).toBe(false);
    expect(isHardBounce({ state: "delivered", bounceKind: null })).toBe(false);
  });

  test("every state we keep is a state Resend sends", () => {
    for (const [type, state] of [
      ["email.sent", "sent"],
      ["email.delivery_delayed", "delayed"],
      ["email.delivered", "delivered"],
      ["email.opened", "opened"],
      ["email.complained", "complained"],
      ["email.bounced", "bounced"],
    ] as const) {
      expect(parseResendEvent(JSON.stringify({ type, data: { email_id: "x" } }))?.state).toBe(
        state,
      );
      expect(DELIVERY_STATES).toContain(state);
    }
  });

  test("an event of another kind is read but keeps no state, and nonsense is not an event", () => {
    const other = parseResendEvent(JSON.stringify({ type: "contact.created", data: {} }));
    expect(other).toMatchObject({ type: "contact.created", state: null, providerMessageId: null });
    expect(parseResendEvent("not json")).toBeNull();
    expect(parseResendEvent("[]")).toBeNull();
    expect(parseResendEvent(JSON.stringify({ data: {} }))).toBeNull();
  });
});

describe("the module the endpoint reads", () => {
  const source = readFileSync(new URL("./resend-webhook.ts", import.meta.url), "utf8");

  test("imports nothing, so Deno can follow it from the Edge Function", () => {
    expect(source).not.toMatch(/^\s*import\s/m);
    expect(source).not.toMatch(/\brequire\(/);
  });

  test("reaches for no runtime of its own: the same check runs under bun and Deno", () => {
    const code = source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
    for (const global of ["process.", "window.", "Deno.", "import.meta", "document."]) {
      expect(code).not.toContain(global);
    }
  });
});
