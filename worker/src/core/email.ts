import type { TenantBinding, WorkerConfig } from "./config.ts";
import { asPrincipal, type Sql } from "./db.ts";

/**
 * The half of email delivery a database cannot do.
 *
 * erp.dispatch_notifications() used to end an email by writing status = 'sent'.
 * Nothing sent it — Postgres cannot make an HTTP request — so the row recorded
 * a delivery that had not happened and never would. 20260904750000 changed
 * dispatch to queue instead, which leaves this file as the only place in the
 * product that actually hands a message to somebody who can post it.
 *
 * Shaped exactly like drainOutbox: claim a batch, deliver one at a time, and
 * report each outcome separately. One message failing must not roll back the
 * ones that already left, which is why every settle is its own statement rather
 * than a batch at the end.
 *
 * The API key is read from the environment, used, and dropped. It is never
 * written back and never logged: a failure's text goes into
 * erp.notification.failure_reason, which is a column somebody can read on a
 * screen, so it must never carry a credential.
 */

const RESEND_ENDPOINT = "https://api.resend.com/emails";

export type EmailRow = {
  id: string;
  to_address: string | null;
  subject: string | null;
  body: string | null;
  from_address: string | null;
  reply_to: string | null;
};

/**
 * What Resend says when it takes a message.
 *
 * The id is the whole point: erp.complete_email() refuses a settle without one,
 * because "sent" should mean a provider named the message rather than that we
 * intended to send it.
 */
type ResendAccepted = { id?: string };

export class PermanentSendFailure extends Error {}

/**
 * Post one message and return the provider's id for it.
 *
 * 4xx other than 429 is the provider saying "never" — a malformed address, an
 * unverified domain, a rejected key. Retrying those is noise that fills the
 * queue and delays everything behind them. 429 and 5xx may be transient and
 * keep their place.
 */
export async function sendViaResend(apiKey: string, row: EmailRow): Promise<string> {
  if (!row.to_address) {
    throw new PermanentSendFailure("the person has no email address");
  }
  if (!row.from_address) {
    throw new PermanentSendFailure("no sender identity resolved for this organisation");
  }

  const response = await fetch(RESEND_ENDPOINT, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      from: row.from_address,
      to: [row.to_address],
      subject: row.subject ?? "(no subject)",
      text: row.body ?? "",
      ...(row.reply_to ? { reply_to: row.reply_to } : {}),
    }),
  });

  if (!response.ok) {
    // Status and a bounded slice of the body. Never the request headers, which
    // is where the key is.
    const detail = (await response.text()).slice(0, 500);
    const message = `resend responded ${response.status}: ${detail}`;
    if (response.status >= 400 && response.status < 500 && response.status !== 429) {
      throw new PermanentSendFailure(message);
    }
    throw new Error(message);
  }

  const accepted = (await response.json()) as ResendAccepted;
  if (!accepted.id) {
    // Accepted without an id is not something to record as sent: the row would
    // fail its own constraint, and we would have no way to match a later
    // delivery or bounce webhook back to it.
    throw new Error("resend accepted the message without returning an id");
  }
  return accepted.id;
}

/**
 * One pass over one organisation's queued email.
 *
 * Returns nothing and throws nothing: an organisation with no key configured is
 * a fact to report once, not a reason to fail the whole drain for every other
 * organisation this worker serves.
 */
export async function drainEmail(
  sql: Sql,
  b: TenantBinding,
  cfg: WorkerConfig,
  out: { emailClaimed: number; emailSent: number; emailFailed: number },
): Promise<void> {
  const apiKey = cfg.resendApiKey;
  if (!apiKey) return;

  const claimed = (await asPrincipal(sql, b, (tx) =>
    tx`select * from erp.claim_email_batch(50)`)) as unknown as EmailRow[];

  if (claimed.length === 0) return;
  out.emailClaimed += claimed.length;

  for (const row of claimed) {
    try {
      const providerId = await sendViaResend(apiKey, row);
      await asPrincipal(sql, b, (tx) =>
        tx`select erp.complete_email(${row.id}::uuid, ${providerId})`);
      out.emailSent += 1;
    } catch (err) {
      const permanent = err instanceof PermanentSendFailure;
      await asPrincipal(sql, b, (tx) =>
        tx`select erp.fail_email(${row.id}::uuid, ${String((err as Error).message)}, ${!permanent})`);
      out.emailFailed += 1;
    }
  }
}
