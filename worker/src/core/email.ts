import {
  composeNotificationEmail,
  type ClaimedNotification,
} from "../../../src/lib/email/notification-email.ts";
import type { TenantBinding, WorkerConfig } from "./config.ts";
import { asPrincipal, type Sql } from "./db.ts";
import { PermanentSendFailure, sendViaResend, type EmailRow } from "./resend.ts";

// Re-exported because this module was the only home for them until the enquiry
// function needed to send as well. The request itself now lives in resend.ts;
// what stays here is the queue around it.
export { PermanentSendFailure, sendViaResend, type EmailRow };

/**
 * The half of email delivery a database cannot do.
 *
 * erp.dispatch_notifications() used to end an email by writing status = 'sent'.
 * Nothing sent it — Postgres cannot make an HTTP request — so the row recorded
 * a delivery that had not happened and never would. 20260904750000 changed
 * dispatch to queue instead, which leaves this file as what drains that queue.
 * The request itself is resend.ts, shared with the enquiry function so that
 * "sent" means the same thing in both places.
 *
 * Shaped exactly like drainOutbox: claim a batch, deliver one at a time, and
 * report each outcome separately. One message failing must not roll back the
 * ones that already left, which is why every settle is its own statement rather
 * than a batch at the end.
 *
 * What a message says is src/lib/email/notification-email.ts: a notification
 * that carries a context (20260914094000) goes out in the shared layout, as
 * HTML and text; one without, or one whose context does not render, goes out
 * as the subject and body it was written with, which is what every email said
 * before. A context that fails to render is logged and never stops the send.
 *
 * The API key is read from the environment, used, and dropped. It is never
 * written back and never logged: a failure's text goes into
 * erp.notification.failure_reason, which is a column somebody can read on a
 * screen, so it must never carry a credential.
 */

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

  const claimed = (await asPrincipal(
    sql,
    b,
    // The claim carries this worker's name and takes a lease, so a message
    // abandoned mid-send is visibly held and reclaimable, not stuck for ever.
    // It also returns the context, the organisation's name and the reader's.
    (tx) => tx`select * from erp.claim_email_batch(50, ${cfg.workerName})`,
  )) as unknown as Array<EmailRow & ClaimedNotification>;

  if (claimed.length === 0) return;
  out.emailClaimed += claimed.length;

  for (const row of claimed) {
    try {
      const message = composeNotificationEmail(row, cfg.appOrigin);
      if (message.fallback !== null) {
        // The id and the reason only: the context holds names and figures,
        // and a log is read by more people than the queue is.
        console.warn(
          `[email] notification ${row.id} went as its plain body: ${message.fallback}`,
        );
      }
      const providerId = await sendViaResend(apiKey, {
        id: row.id,
        to_address: row.to_address,
        from_address: row.from_address,
        reply_to: row.reply_to,
        subject: message.subject,
        body: message.body,
        html: message.html,
      });
      await asPrincipal(
        sql,
        b,
        (tx) => tx`select erp.complete_email(${row.id}::uuid, ${providerId})`,
      );
      out.emailSent += 1;
    } catch (err) {
      const permanent = err instanceof PermanentSendFailure;
      await asPrincipal(
        sql,
        b,
        (tx) =>
          tx`select erp.fail_email(${row.id}::uuid, ${String((err as Error).message)}, ${!permanent})`,
      );
      out.emailFailed += 1;
    }
  }
}
