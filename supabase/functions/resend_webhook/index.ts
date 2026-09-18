/**
 * What the provider tells us after a message leaves.
 *
 * Sending is not delivering. Until this endpoint existed, every email the
 * product sent was recorded as "sent" and nothing ever said whether it
 * arrived: a customer whose address had a typo in it was chased by silence,
 * and a bounce was invisible to everybody. Resend knows, and will post what it
 * knows here.
 *
 * The whole of this file is: is this request Resend's, and if it is, hand the
 * one event it carries to the database. Nothing else is decided here — which
 * message an event belongs to, what state that message is now in, whether an
 * address should be suppressed and what to audit are all
 * erp.record_email_delivery_event(), which is where they can be proved by a
 * suite.
 *
 * Verification is src/lib/email/resend-webhook.ts, which imports nothing, so
 * Deno can follow it and bun can test it: Resend signs the way Svix does, over
 * the id, the timestamp and the exact bytes of the body, so the body is read
 * once as text and never re-serialised.
 *
 * The secret. Resend shows a signing secret (whsec_…) when the endpoint is
 * added. It belongs in the vault, beside the dispatch secret:
 *
 *   select vault.create_secret('whsec_…', 'cloveerp_resend_webhook_secret',
 *          'Signing secret for the Resend webhook endpoint.');
 *
 * or, for a host without the vault, in CLOVEERP_RESEND_WEBHOOK_SECRET. Until
 * one of the two is set this endpoint refuses every request and records
 * nothing, which is the only safe reading of "anyone may post here".
 *
 * verify_jwt is false in supabase/config.toml, as it is for dispatch: Resend
 * sends no Authorization header, so the gateway would refuse every event
 * before this file ran. The signature is the gate.
 */
import {
  parseResendEvent,
  verifyResendWebhook,
  webhookHeaders,
} from "../../../src/lib/email/resend-webhook.ts";
import { connect, declaring, type Sql } from "../../../worker/src/core/db.ts";

// deno-lint-ignore no-explicit-any
const Deno = (globalThis as any).Deno;

/** The vault entry the owner creates once, named as the dispatch secret is. */
const SECRET_NAME = "cloveerp_resend_webhook_secret";

/** How long one isolate trusts what it read from the vault, as dispatch does. */
const VALUE_TTL_MS = 5 * 60_000;
const ABSENT_TTL_MS = 30_000;

let cached: { value: string | null; until: number } | null = null;
let reading: Promise<string | null> | null = null;

function databaseUrl(env: Record<string, string | undefined>): string | null {
  return env["CLOVEERP_DATABASE_URL"]?.trim() || env["SUPABASE_DB_URL"]?.trim() || null;
}

function vaultSecret(sql: Sql): Promise<string | null> {
  if (cached !== null && cached.until > Date.now()) return Promise.resolve(cached.value);
  reading ??= (async () => {
    try {
      const rows = (await sql`
        select s.decrypted_secret from vault.decrypted_secrets s where s.name = ${SECRET_NAME} limit 1
      `) as unknown as Array<Record<string, unknown>>;
      const raw = rows[0]?.["decrypted_secret"];
      const value = typeof raw === "string" && raw.trim().length > 0 ? raw.trim() : null;
      cached = { value, until: Date.now() + (value === null ? ABSENT_TTL_MS : VALUE_TTL_MS) };
      return value;
    } finally {
      reading = null;
    }
  })();
  return reading;
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "post an event" }, 405);

  const env = Deno.env.toObject() as Record<string, string | undefined>;
  let sql: Sql | undefined;
  try {
    // The exact bytes that were signed, read once.
    const body = await req.text();
    if (body.length > 256_000) return json({ error: "that is not an event" }, 413);

    const fromEnv = env["CLOVEERP_RESEND_WEBHOOK_SECRET"]?.trim() || null;
    const url = databaseUrl(env);
    if (url === null) {
      return json(
        {
          error:
            "neither CLOVEERP_DATABASE_URL nor SUPABASE_DB_URL is set, so nothing can be " +
            "read from the vault and no event can be recorded",
        },
        500,
      );
    }
    sql = connect(url, "edge_function");

    let secret = fromEnv;
    if (secret === null) {
      try {
        secret = await vaultSecret(sql);
      } catch (err) {
        // The detail is for the log: a connection error can name a host, and
        // the caller has not yet shown a signature.
        console.error(`[resend-webhook] the vault could not be read: ${(err as Error).message}`);
        return json({ error: "the signing secret could not be read; the function log says why" }, 500);
      }
    }
    if (secret === null) {
      console.warn(
        `[resend-webhook] refused: the vault has no ${SECRET_NAME} and ` +
          "CLOVEERP_RESEND_WEBHOOK_SECRET is not set",
      );
      return json(
        {
          error:
            `no webhook signing secret exists: add it to the vault as ${SECRET_NAME} ` +
            "(Resend shows it when the endpoint is created); until then every event is refused",
        },
        401,
      );
    }

    const verdict = await verifyResendWebhook({
      headers: webhookHeaders(req.headers),
      body,
      secret,
    });
    if (!verdict.ok) {
      // The reason is logged, never returned: an unsigned caller learns only
      // that it was refused.
      console.warn(`[resend-webhook] refused: ${verdict.reason}`);
      return json({ error: "unauthorised" }, 401);
    }

    const event = parseResendEvent(body);
    if (event === null) return json({ error: "that is not an event" }, 400);

    // One row, one decision, all of it in the database: what the event means,
    // which message it belongs to, whether it has been seen before, and
    // whether the address should now be suppressed.
    const rows = (await declaring(
      sql,
      (tx) =>
        tx`
      select erp.record_email_delivery_event(
               ${verdict.eventId}, ${event.type}, ${event.state},
               ${event.providerMessageId}, ${event.occurredAt}::timestamptz,
               ${event.recipient}, ${event.bounceKind}, ${event.detail}) as result
    `,
    )) as unknown as Array<{ result: unknown }>;

    // 200 whatever the database made of it: an event we cannot match is not a
    // reason for the provider to send it again, and a replay is not an error.
    return json(rows[0]?.result ?? { recorded: false }, 200);
  } catch (err) {
    console.error(`[resend-webhook] ${(err as Error).message}`);
    return json({ error: "the event could not be recorded" }, 500);
  } finally {
    await sql?.end({ timeout: 5 });
  }
});
