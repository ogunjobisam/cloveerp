import type { TenantBinding, WorkerConfig } from "./config.ts";
import { resolveCredential } from "./config.ts";
import { asPrincipal, type Sql } from "./db.ts";

/**
 * The half of webhook delivery a database cannot do.
 *
 * erp.dispatch_notifications() used to end a webhook notification by writing
 * status = 'sent'. Nothing sent it — Postgres cannot make an HTTP request — so
 * the row recorded a delivery that had not happened and never would. That is
 * the same fault the email queue had before 20260904750000, and
 * 20260906144000 corrects it the same way: dispatch queues, and this file is
 * what drains that queue.
 *
 * Shaped exactly like drainEmail, which is shaped like drainOutbox: claim a
 * batch under a lease, deliver one at a time, and settle each outcome in its
 * own statement. One message failing must not roll back the ones that already
 * left.
 *
 * The credential is resolved from the channel's reference, used, and dropped.
 * It is never written back and never logged: a failure's text goes into
 * erp.notification.failure_reason, which is a column somebody reads on a
 * screen, so it must never carry a secret.
 */

/** One row of erp.claim_webhook_batch(): a message and where it goes. */
export type WebhookRow = {
  id: string;
  url: string | null;
  credential_ref: string | null;
  channel_code: string | null;
  payload: unknown;
  severity: string | null;
};

/** The counterpart answered, and said no. */
export class WebhookRefused extends Error {
  constructor(
    message: string,
    public readonly status: number,
  ) {
    super(message);
  }
}

/**
 * Post one message and return what the other end said.
 *
 * The receipt is the point: erp.complete_webhook() refuses a settle without
 * one, because "sent" should mean somebody answered rather than that we
 * intended to send. A receiver that returns an id gets quoted; one that
 * returns nothing useful is recorded by its status, which is still evidence
 * that the request completed.
 */
export async function deliverWebhook(
  row: WebhookRow,
  credential: string | null,
  timeoutMs: number,
): Promise<string> {
  if (!row.url) {
    throw new WebhookRefused(`channel ${row.channel_code ?? "?"} has no URL configured`, 0);
  }

  let response: Response;
  try {
    response = await fetch(row.url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(credential ? { authorization: `Bearer ${credential}` } : {}),
        // The message's own id is its key on the wire, so a receiver can tell
        // a retry of this message from a second message that looks alike.
        "idempotency-key": `clove-notification-${row.id}`,
      },
      body: JSON.stringify(row.payload),
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (err) {
    // No answer of any kind. Retryable: unlike a command, a notification the
    // counterpart may or may not have is not a write we must not repeat — a
    // second copy of a message is better than a person never being told.
    throw new Error(`no answer within ${timeoutMs} ms: ${(err as Error).name}`);
  }

  if (!response.ok) {
    // Status and a bounded slice of the body. Never the request headers,
    // which is where the credential is.
    const body = (await response.text()).slice(0, 300);
    throw new WebhookRefused(`endpoint responded ${response.status}: ${body}`, response.status);
  }

  const text = (await response.text().catch(() => "")).slice(0, 200);
  const id = ((): string | null => {
    try {
      const parsed = JSON.parse(text) as Record<string, unknown>;
      const value = parsed["id"] ?? parsed["message_id"] ?? parsed["ts"];
      return typeof value === "string" || typeof value === "number" ? String(value) : null;
    } catch {
      return null;
    }
  })();

  return id ? `http ${response.status} ${id}` : `http ${response.status}`;
}

/**
 * One pass over one organisation's queued webhook notifications.
 *
 * Returns nothing and throws nothing: an organisation with no webhook channel
 * configured claims nothing and is not a reason to fail the drain for every
 * other organisation this worker serves.
 */
export async function drainWebhooks(
  sql: Sql,
  b: TenantBinding,
  cfg: WorkerConfig,
  out: { webhooksClaimed: number; webhooksSent: number; webhooksFailed: number },
): Promise<void> {
  const claimed = (await asPrincipal(
    sql,
    b,
    (tx) => tx`select * from erp.claim_webhook_batch(50, ${cfg.workerName})`,
  )) as unknown as WebhookRow[];

  if (claimed.length === 0) return;
  out.webhooksClaimed += claimed.length;

  for (const row of claimed) {
    let credential: string | null = null;
    try {
      credential = resolveCredential(row.credential_ref ?? null);
    } catch (err) {
      // A reference that resolves to nothing in this environment is a
      // configuration fault, and a permanent one for this pass.
      await asPrincipal(
        sql,
        b,
        (tx) =>
          tx`select erp.fail_webhook(${row.id}::uuid, ${String((err as Error).message)}, false)`,
      );
      out.webhooksFailed += 1;
      continue;
    }

    try {
      const receipt = await deliverWebhook(row, credential, cfg.httpTimeoutMs);
      await asPrincipal(
        sql,
        b,
        (tx) => tx`select erp.complete_webhook(${row.id}::uuid, ${receipt})`,
      );
      out.webhooksSent += 1;
    } catch (err) {
      // 4xx other than 429 is the receiver saying "never": a malformed
      // payload, a revoked token, a URL that is gone. Retrying those fills the
      // queue and delays everything behind them. Everything else may be
      // transient and keeps its attempts, up to the fifth, when
      // erp.fail_webhook() tells the person in-app instead.
      const permanent =
        err instanceof WebhookRefused &&
        err.status >= 400 &&
        err.status < 500 &&
        err.status !== 429;
      await asPrincipal(
        sql,
        b,
        (tx) =>
          tx`select erp.fail_webhook(${row.id}::uuid, ${String((err as Error).message)}, ${!permanent})`,
      );
      out.webhooksFailed += 1;
    }
  }
}
