import { describe, expect, test } from "bun:test";

import { outcomeFor } from "../routes/contact";
import {
  DEMO_REQUESTED_EVENT,
  FOUNDING_SEGMENT_ID,
  maybeSubscribeToFollowUps,
  SIGNUP_SOURCE,
  splitName,
  subscribeToFollowUps,
} from "./resend-marketing";

/**
 * The follow-up list only ever hears about somebody who asked for it, and
 * whatever it does or fails to do must leave the enquiry's own outcome alone.
 */

type Call = { url: string; body: Record<string, unknown> };

function recorder(responses: Array<{ status: number; json?: Record<string, unknown> }>) {
  const calls: Call[] = [];
  const doFetch = (async (url: string | URL | Request, init?: RequestInit) => {
    const next = responses[calls.length] ?? { status: 200, json: {} };
    calls.push({
      url: String(url),
      body: JSON.parse((init?.body as string) || "{}") as Record<string, unknown>,
    });
    return {
      status: next.status,
      json: async () => next.json ?? {},
    } as unknown as Response;
  }) as unknown as typeof fetch;
  return { calls, doFetch };
}

const SIGNUP = {
  email: "dana@okaforfoods.co.uk",
  fullName: "Dana Okafor",
  organisation: "Okafor Foods",
  businessType: "Manufacturing",
  currentSystem: "Xero + spreadsheets",
};

describe("who reaches the follow-up list", () => {
  test("a ticked box creates the contact, then the segment, then the event", async () => {
    const { calls, doFetch } = recorder([
      { status: 201, json: { id: "con_1" } },
      { status: 200 },
      { status: 200 },
    ]);

    const outcome = await subscribeToFollowUps("re_key", SIGNUP, {
      fetch: doFetch,
      baseUrl: "https://api.resend.test",
    });

    expect(outcome).toEqual({ ok: true, failure: null });
    expect(calls.map((c) => c.url)).toEqual([
      "https://api.resend.test/contacts",
      `https://api.resend.test/contacts/con_1/segments/${FOUNDING_SEGMENT_ID}`,
      "https://api.resend.test/events/send",
    ]);
    expect(calls[0]?.body).toEqual({
      email: SIGNUP.email,
      first_name: "Dana",
      last_name: "Okafor",
      unsubscribed: false,
      properties: {
        company_name: "Okafor Foods",
        business_type: "Manufacturing",
        current_system: "Xero + spreadsheets",
        signup_source: SIGNUP_SOURCE,
      },
    });
    expect(calls[2]?.body).toEqual({
      event: DEMO_REQUESTED_EVENT,
      email: SIGNUP.email,
      payload: {
        company_name: "Okafor Foods",
        business_type: "Manufacturing",
        current_system: "Xero + spreadsheets",
        signup_source: SIGNUP_SOURCE,
      },
    });
  });

  test("one name is a first name, not a repeated surname", () => {
    expect(splitName("Dana")).toEqual({ firstName: "Dana", lastName: "" });
    expect(splitName("  Siobhan  O'Brien  ")).toEqual({
      firstName: "Siobhan",
      lastName: "O'Brien",
    });
  });

  test("a refused contact stops before the segment and names the reason", async () => {
    const { calls, doFetch } = recorder([{ status: 422, json: { message: "invalid email" } }]);

    const outcome = await subscribeToFollowUps("re_key", SIGNUP, { fetch: doFetch });

    expect(outcome.ok).toBe(false);
    expect(outcome.failure).toContain("resend contact failed (422)");
    expect(calls).toHaveLength(1);
  });

  test("a thrown request is reported, not raised", async () => {
    const doFetch = (async () => {
      throw new Error("timed out");
    }) as unknown as typeof fetch;

    const outcome = await subscribeToFollowUps("re_key", SIGNUP, { fetch: doFetch });

    expect(outcome.ok).toBe(false);
    expect(outcome.failure).toContain("timed out");
  });
});

describe("the consent gate", () => {
  test("an unticked box makes no Resend calls at all", async () => {
    const { calls, doFetch } = recorder([]);

    const outcome = await maybeSubscribeToFollowUps("re_key", false, SIGNUP, { fetch: doFetch });

    expect(outcome).toBeNull();
    expect(calls).toHaveLength(0);
  });

  test("a ticked box goes through the same three calls", async () => {
    const { calls, doFetch } = recorder([
      { status: 201, json: { id: "con_2" } },
      { status: 200 },
      { status: 200 },
    ]);

    const outcome = await maybeSubscribeToFollowUps("re_key", true, SIGNUP, { fetch: doFetch });

    expect(outcome).toEqual({ ok: true, failure: null });
    expect(calls).toHaveLength(3);
  });

  test("a Resend failure leaves what the page shows exactly as it was", async () => {
    // The enquiry's own outcome is decided by outcomeFor and nothing else.
    // Resend falling over is a log line, not a different answer to the sender.
    const doFetch = (async () => {
      throw new Error("resend is down");
    }) as unknown as typeof fetch;

    const stored = { stored: true, notified: true };
    const followUp = await maybeSubscribeToFollowUps("re_key", true, SIGNUP, { fetch: doFetch });

    expect(followUp?.ok).toBe(false);
    expect(outcomeFor(stored.stored, { notified: stored.notified })).toEqual({ kind: "answered" });
  });
});
