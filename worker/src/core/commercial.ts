import {
  CommercialEmailError,
  composeCommercialEmail,
  type ClaimedCommercialEmail,
} from "../../../src/lib/email/commercial-email.ts";
import type { WorkerConfig } from "./config.ts";
import type { Sql } from "./db.ts";
import { PermanentSendFailure, sendViaResend } from "./resend.ts";

/**
 * Issued order forms and contract invoices, on their way to the customer.
 *
 * Issuing either one queues a row per recipient in erp_meta.commercial_email
 * (20260914097200). Those rows belong to the platform, not to any one
 * organisation, so this stage runs once a pass, outside the loop over
 * organisations, over the drain's own trusted connection:
 * erp.claim_commercial_email_batch() refuses anybody else, sets the platform
 * organisation as the context itself, and stops for its email kill switch.
 *
 * Shaped like drainEmail: claim a batch, send one at a time, and settle each on
 * its own, so one failure never takes back a message that already left. What a
 * message says is src/lib/email/commercial-email.ts. A payload that cannot be
 * made into an email is failed for good rather than sent half-written; a
 * provider's "never" is failed for good; anything else is tried again.
 *
 * Every message carries its idempotency key, so one whose settle was lost after
 * the provider took it is not delivered twice when its lease runs out.
 *
 * The log names ids only: a payload holds names, prices and bank details, and a
 * log is read by more people than the queue is.
 */

export type CommercialEmailCounts = {
  commercialEmailClaimed: number;
  commercialEmailSent: number;
  commercialEmailFailed: number;
};

/** Up to this many a pass: the minute cron comes round again soon enough. */
export const COMMERCIAL_EMAIL_BATCH = 20;

/** Whether a failure should be tried again on a later pass. */
export function worthRetrying(err: unknown): boolean {
  return !(err instanceof PermanentSendFailure || err instanceof CommercialEmailError);
}

export async function drainCommercialEmail(
  sql: Sql,
  cfg: WorkerConfig,
  out: CommercialEmailCounts,
): Promise<void> {
  const apiKey = cfg.resendApiKey;
  if (!apiKey) return;

  const claimed = (await sql.begin(
    (tx) =>
      tx`select * from erp.claim_commercial_email_batch(${COMMERCIAL_EMAIL_BATCH}, ${cfg.workerName})`,
  )) as unknown as ClaimedCommercialEmail[];

  if (claimed.length === 0) return;
  out.commercialEmailClaimed += claimed.length;

  for (const row of claimed) {
    try {
      const message = composeCommercialEmail(row, cfg.appOrigin);
      const providerId = await sendViaResend(apiKey, {
        id: row.email_id,
        to_address: row.recipient_address,
        from_address: row.sender_address,
        reply_to: row.reply_address,
        subject: message.subject,
        body: message.text,
        html: message.html,
        idempotency_key: row.send_key,
      });
      await sql.begin(
        (tx) => tx`select erp.complete_commercial_email(${row.email_id}::uuid, ${providerId})`,
      );
      out.commercialEmailSent += 1;
    } catch (err) {
      const retry = worthRetrying(err);
      console.warn(
        `[commercial-email] ${row.email_id} (${row.email_kind}) was not sent; ${retry ? "it will be tried again" : "it is failed"}`,
      );
      await sql.begin(
        (tx) =>
          tx`select erp.fail_commercial_email(${row.email_id}::uuid, ${String((err as Error).message)}, ${retry})`,
      );
      out.commercialEmailFailed += 1;
    }
  }
}
