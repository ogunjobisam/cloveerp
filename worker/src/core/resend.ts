/**
 * Handing one message to somebody who can post it.
 *
 * Extracted from email.ts when the enquiry function needed to send too. The
 * point of the extraction is that there is one of these: two places calling a
 * provider means two opinions about what "sent" means, and this codebase has
 * spent enough time on rows that recorded an outcome nothing produced.
 *
 * email.ts still owns the queue — claiming a batch, settling each row, tenant
 * by tenant. This file owns only the request, and knows nothing about a
 * database.
 *
 * The API key arrives as an argument, is used, and is dropped. It is never
 * written back and never logged: a failure's text goes into a column somebody
 * reads on a screen, so it must never carry a credential.
 */

/**
 * Where the request goes. Resend's API, unless the environment names another
 * endpoint — which only the build does, pointing it at a stub that records
 * the request and answers with an id, so "sent" can be proved without a key.
 * Read from whichever runtime is hosting this file: Bun and Node carry
 * process.env, Deno carries Deno.env.
 */
function resendEndpoint(): string {
  const g = globalThis as unknown as {
    process?: { env?: Record<string, string | undefined> };
    Deno?: { env?: { get(name: string): string | undefined } };
  };
  const override = g.process?.env?.["CLOVEERP_RESEND_ENDPOINT"] ?? g.Deno?.env?.get("CLOVEERP_RESEND_ENDPOINT");
  return override && override.trim().length > 0 ? override.trim() : "https://api.resend.com/emails";
}

const RESEND_ENDPOINT = resendEndpoint();

export type EmailRow = {
  id: string;
  to_address: string | null;
  subject: string | null;
  body: string | null;
  from_address: string | null;
  reply_to: string | null;
  /**
   * An HTML alternative, when the caller has one.
   *
   * Optional, and absent for everything the queue in email.ts sends: those
   * bodies come out of erp.notification_template and are text. The enquiry
   * function sets it, so the person reading a lead gets something laid out
   * rather than a wall of lines.
   *
   * body stays required when this is set, and stays the whole message rather
   * than a stub pointing at the HTML. A text part that says "view this in a
   * modern client" is a message that failed to arrive for anyone reading mail
   * as text, and a missing text part is a spam signal besides.
   */
  html?: string | null;
};

/**
 * What Resend says when it takes a message.
 *
 * The id is the whole point: erp.complete_email() and
 * erp.complete_enquiry_notice() both refuse a settle without one, because
 * "sent" should mean a provider named the message rather than that we intended
 * to send it.
 */
type ResendAccepted = { id?: string };

export class PermanentSendFailure extends Error {}

/**
 * A sender address as a setting may hold it, made into one Resend accepts.
 *
 * On 4 September two enquiries failed with Resend's 422 "Invalid `from`
 * field": CLOVEERP_ENQUIRY_FROM is documented as
 * CLOVEERP_ENQUIRY_FROM='Clove ERP <hello@cloveerp.com>', and pasted into a
 * dashboard rather than a shell those quotes stay in the value. Surrounding
 * whitespace and one pair of matching quotes are taken off; nothing else is
 * guessed at.
 */
export function normaliseSender(value: string): string {
  const trimmed = value.trim();
  const quoted = /^(['"])(.*)\1$/s.exec(trimmed);
  return (quoted?.[2] ?? trimmed).trim();
}

const ADDRESS = "[^\\s@<>\"']+@[^\\s@<>\"']+\\.[^\\s@<>\"']+";
const BARE = new RegExp(`^${ADDRESS}$`);
const NAMED = new RegExp(`^(.*\\S)\\s*<${ADDRESS}>$`);

/** A display name: either wholly in double quotes, or with no quote at either end. */
function nameIsWhole(name: string): boolean {
  if (/^"[^"]+"$/.test(name)) return true;
  return !/^["']|["']$/.test(name) && !name.includes('"') && !/[<>]/.test(name);
}

/**
 * Why a sender address would be refused, in words for the screen that shows
 * the failure, or null when it is one of the two shapes Resend takes:
 * email@example.com or Name <email@example.com>.
 *
 * Checked before the request, so a malformed setting fails with a reason that
 * names the setting's shape instead of a provider's validation error, and
 * without spending a request on a message that could never be sent.
 */
export function senderProblem(from: string): string | null {
  const value = from.trim();
  if (value === "") return "no sender address is set";
  if (BARE.test(value)) return null;
  const named = NAMED.exec(value);
  if (named && nameIsWhole((named[1] ?? "").trim())) return null;
  return `the sender address ${JSON.stringify(value)} is neither "email@example.com" nor "Name <email@example.com>"; correct the setting that supplies it`;
}

/**
 * Post one message and return the provider's id for it.
 *
 * text always, html as well when the row carries one: Resend accepts both and
 * sends a multipart message, which is what lets a client that renders HTML and
 * one that does not each show the whole thing.
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
  const from = normaliseSender(row.from_address);
  const problem = senderProblem(from);
  if (problem) {
    throw new PermanentSendFailure(problem);
  }

  const response = await fetch(RESEND_ENDPOINT, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      from,
      to: [row.to_address],
      subject: row.subject ?? "(no subject)",
      text: row.body ?? "",
      ...(row.html ? { html: row.html } : {}),
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
