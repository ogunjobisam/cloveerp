/**
 * Every message carries a reply-to.
 *
 * Run it with:
 *
 *   deno test --allow-env=CLOVEERP_RESEND_ENDPOINT,EMAIL_REPLY_TO \
 *     worker/test/email_reply_to_test.ts
 *
 * A Deno test rather than a Bun one because the Edge Functions are the callers
 * that send with no reply-to of their own, and Deno is the runtime that runs
 * them. It sits here, beside the worker's other tests of this file, rather than
 * next to the helper itself: worker/src is typechecked by tsc with Node's
 * types, where Deno.test does not exist.
 *
 * fetch is stubbed. Nothing here reaches Resend, and no key is needed: the
 * assertion is about the request we build, which is the whole of the change.
 */

import { sendViaResend } from "../src/core/resend.ts";

type Sent = { reply_to?: string; from: string; to: string[] };

/** Stand in for Resend: record one request body, answer with an id. */
function capture(): { body(): Sent; restore(): void } {
  const original = globalThis.fetch;
  let seen: Sent | null = null;
  globalThis.fetch = ((_input: unknown, init?: { body?: string }) => {
    seen = JSON.parse(init?.body ?? "{}") as Sent;
    return Promise.resolve(
      new Response(JSON.stringify({ id: "test-message-id" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    );
  }) as typeof globalThis.fetch;
  return {
    body() {
      if (seen === null) throw new Error("nothing was sent");
      return seen;
    },
    restore() {
      globalThis.fetch = original;
    },
  };
}

const message = {
  id: "11111111-1111-1111-1111-111111111111",
  to_address: "person@example.com",
  subject: "A subject",
  body: "A message.",
  from_address: "Clove ERP <no-reply@cloveerp.com>",
};

function equal(actual: unknown, expected: unknown, what: string): void {
  if (actual !== expected) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

Deno.test("a message with no reply-to of its own answers to support@", async () => {
  const resend = capture();
  try {
    const id = await sendViaResend("test-key", { ...message, reply_to: null });
    equal(id, "test-message-id", "the provider's id is returned");
    equal(resend.body().reply_to, "support@cloveerp.com", "reply_to");
  } finally {
    resend.restore();
  }
});

Deno.test("a caller that names its own reply-to keeps it", async () => {
  const resend = capture();
  try {
    await sendViaResend("test-key", { ...message, reply_to: "enquirer@example.com" });
    equal(resend.body().reply_to, "enquirer@example.com", "reply_to");
  } finally {
    resend.restore();
  }
});
