/**
 * Where a carrier says a shipment is (20261004965000).
 *
 * Each organisation connects its own EasyPost account and adds this address
 * in EasyPost under Webhooks, with ?org=<its code> (erp_carrier_account()
 * prints it) and a signing secret it gives Clove when it connects. EasyPost
 * signs every event with that secret, HMAC-SHA256 over the exact body, in
 * X-Hmac-Signature.
 *
 * The whole of this file is: whose is this, is it really EasyPost's, and if
 * it is, hand the one tracker event to the database. Which shipment it
 * belongs to, whether it moves the shipment forward, and whether an outbound
 * shipment is now delivered are all erp.record_carrier_tracking(), proved by
 * erp_test.carrier_integration_suite. Verification is
 * src/lib/carriers/easypost.ts, which imports nothing, so Deno can follow it
 * and bun can test it.
 *
 * The secret is the organisation's, in the vault, read by
 * erp.carrier_webhook_secret() over this function's own connection. An
 * organisation that gave none has every event refused: anyone may post here,
 * and an unsigned event is nobody's.
 *
 * verify_jwt is false in supabase/config.toml, as it is for resend_webhook:
 * EasyPost sends no Authorization header. The signature is the gate.
 */
import {
  SIGNATURE_HEADER,
  parseTrackingEvent,
  verifyCarrierWebhook,
} from "../../../src/lib/carriers/easypost.ts";
import { connect, declaring, type Sql } from "../../../worker/src/core/db.ts";

// deno-lint-ignore no-explicit-any
const Deno = (globalThis as any).Deno;

function databaseUrl(env: Record<string, string | undefined>): string | null {
  return env["CLOVEERP_DATABASE_URL"]?.trim() || env["SUPABASE_DB_URL"]?.trim() || null;
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "post an event" }, 405);

  const org = new URL(req.url).searchParams.get("org")?.trim() ?? "";
  if (!/^[a-z0-9][a-z0-9-]{1,62}$/.test(org)) return json({ error: "name the organisation" }, 400);

  const env = Deno.env.toObject() as Record<string, string | undefined>;
  let sql: Sql | undefined;
  try {
    // The exact bytes that were signed, read once.
    const body = await req.text();
    if (body.length > 256_000) return json({ error: "that is not an event" }, 413);

    const url = databaseUrl(env);
    if (url === null) {
      return json({ error: "no database is configured, so no event can be recorded" }, 500);
    }
    sql = connect(url, "edge_function");

    const rows = (await declaring(
      sql,
      (tx) => tx`select erp.carrier_webhook_secret(${org}) as secret`,
    )) as unknown as Array<{ secret: string | null }>;

    const verdict = await verifyCarrierWebhook({
      body,
      signature: req.headers.get(SIGNATURE_HEADER),
      secret: rows[0]?.secret ?? null,
    });
    if (!verdict.ok) {
      // The reason is logged, never returned: an unsigned caller learns only
      // that it was refused.
      console.warn(`[carrier-webhook] refused for ${org}: ${verdict.reason}`);
      return json({ error: "unauthorised" }, 401);
    }

    const event = parseTrackingEvent(body);
    // Not a tracker event: nothing to record, and nothing for EasyPost to resend.
    if (event === null) return json({ recorded: false }, 200);

    const result = (await declaring(
      sql,
      (tx) =>
        tx`select erp.record_carrier_tracking(${org}, ${event.eventId}, ${event.trackingCode},
                 ${event.status}, ${event.occurredAt}::timestamptz, ${event.detail}) as result`,
    )) as unknown as Array<{ result: unknown }>;

    // 200 whatever the database made of it: an event for a shipment we do not
    // know is not a reason to send it again, and a replay is not an error.
    return json(result[0]?.result ?? { recorded: false }, 200);
  } catch (err) {
    console.error(`[carrier-webhook] ${(err as Error).message}`);
    return json({ error: "the event could not be recorded" }, 500);
  } finally {
    await sql?.end({ timeout: 5 });
  }
});
