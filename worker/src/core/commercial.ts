import {
  CommercialEmailError,
  composeCommercialEmail,
  type ClaimedCommercialEmail,
} from "../../../src/lib/email/commercial-email.ts";
import type { WorkerConfig } from "./config.ts";
import type { Sql } from "./db.ts";
import { PermanentSendFailure, sendViaResend, type EmailRow } from "./resend.ts";

/**
 * Issued order forms and contract invoices, on their way to the customer.
 *
 * Issuing either one queues a row per recipient in erp_meta.commercial_email
 * (20260914097300). Those rows belong to the platform, not to any one
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
 * The document goes with it as a PDF (20260915020000). It is made from the same
 * payload by src/lib/pdf/commercial-document.ts, attached, and a copy is kept
 * in the private document-output bucket under this send's own path, which the
 * settle records with its size and checksum once the archive holds it. None of
 * that can stop the email: a document that cannot be made, a provider that
 * refuses the attachment, or a copy that cannot be kept is a reason recorded on
 * the row, and the message goes as it did before there was a PDF.
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

/* -------------------------------------------------------------------------- */
/* The PDF                                                                    */
/* -------------------------------------------------------------------------- */

type Renderer = typeof import("../../../src/lib/pdf/commercial-document.ts");

let rendererLoad: Promise<Renderer> | null = null;

/**
 * The renderer, loaded the first time a document is wanted.
 *
 * Loaded rather than imported at the top so that a runtime which cannot
 * resolve pdf-lib still sends email: the Edge Function resolves it through
 * supabase/functions/import_map.json, and a Bun worker from a checkout whose
 * root dependencies are installed; a worker without them records why the
 * document is missing instead of failing to start. The specifier is a literal,
 * so the Edge Function's bundle carries the module. A failed load is forgotten,
 * so the next message tries again.
 */
export function loadCommercialDocumentRenderer(): Promise<Renderer> {
  rendererLoad ??= import("../../../src/lib/pdf/commercial-document.ts").catch((err: unknown) => {
    rendererLoad = null;
    throw err;
  });
  return rendererLoad;
}

/** A reason for the screen that shows it: one line, bounded, and never a stack. */
export function documentReason(what: string, err: unknown): string {
  const detail = err instanceof Error ? err.message : String(err);
  return `${what}: ${detail.replace(/\s+/g, " ").trim()}`.slice(0, 300);
}

export type MadeDocument =
  | { ok: true; filename: string; path: string; pdf: Uint8Array; sha256: string; base64: string }
  | { ok: false; problem: string };

/** The PDF for one claimed row. Never throws: a document that cannot be made says why. */
export async function makeCommercialDocument(
  row: Pick<ClaimedCommercialEmail, "email_id" | "email_kind" | "payload">,
  load: () => Promise<Renderer> = loadCommercialDocumentRenderer,
): Promise<MadeDocument> {
  try {
    const r = await load();
    const pdf = await r.renderCommercialDocumentPdf(row.payload);
    return {
      ok: true,
      filename: r.commercialDocumentFilename(row.payload, row.email_kind),
      path: r.commercialDocumentPath(row.email_kind, row.email_id),
      pdf,
      sha256: await r.sha256Hex(pdf),
      base64: r.pdfToBase64(pdf),
    };
  } catch (err) {
    return { ok: false, problem: documentReason("no PDF could be made, so the email went without one", err) };
  }
}

type Fetch = (input: string, init: RequestInit) => Promise<Response>;

/**
 * Keep the copy in the document-output bucket, through the Storage API with the
 * service role, as the preview sweep in drain.ts removes previews. Overwrites
 * the same path, so a send tried again keeps one copy. Returns null when the
 * copy is kept, or why it is not. Never throws.
 */
export async function keepCommercialDocument(
  cfg: Pick<WorkerConfig, "supabaseUrl" | "supabaseServiceRoleKey" | "httpTimeoutMs">,
  path: string,
  pdf: Uint8Array,
  fetchImpl: Fetch = fetch,
): Promise<string | null> {
  if (!cfg.supabaseUrl || !cfg.supabaseServiceRoleKey) {
    return "no storage is configured for the drain, so no copy was kept";
  }
  try {
    const base = cfg.supabaseUrl.replace(/\/+$/, "");
    const response = await fetchImpl(`${base}/storage/v1/object/document-output/${path}`, {
      method: "POST",
      headers: {
        apikey: cfg.supabaseServiceRoleKey,
        Authorization: `Bearer ${cfg.supabaseServiceRoleKey}`,
        "content-type": "application/pdf",
        "x-upsert": "true",
      },
      body: pdf as unknown as BodyInit,
      signal: AbortSignal.timeout(cfg.httpTimeoutMs),
    });
    if (!response.ok) {
      // The status only: a storage error body can echo the request.
      return `the copy could not be kept: storage responded ${response.status}`;
    }
    return null;
  } catch (err) {
    return documentReason("the copy could not be kept", err);
  }
}

/* -------------------------------------------------------------------------- */
/* Sending                                                                    */
/* -------------------------------------------------------------------------- */

export type SentCommercialEmail = {
  providerId: string;
  documentPath: string | null;
  documentBytes: number | null;
  documentSha256: string | null;
  documentProblem: string | null;
};

type Send = (apiKey: string, row: EmailRow) => Promise<string>;

/**
 * Make the document, send the message with it, and keep the copy: everything
 * one row needs before its settle. Throws only what the email itself would have
 * thrown before there was a PDF, so the caller fails the row exactly as before.
 */
export async function sendCommercialEmail(
  row: ClaimedCommercialEmail,
  cfg: Pick<WorkerConfig, "appOrigin" | "supabaseUrl" | "supabaseServiceRoleKey" | "httpTimeoutMs">,
  apiKey: string,
  deps: { send?: Send; fetch?: Fetch; load?: () => Promise<Renderer> } = {},
): Promise<SentCommercialEmail> {
  const send = deps.send ?? sendViaResend;
  // An email that cannot be written fails before any document is made.
  composeCommercialEmail(row, cfg.appOrigin);

  const doc = await makeCommercialDocument(row, deps.load);
  const problems: string[] = doc.ok ? [] : [doc.problem];

  const envelope = (attached: string | null): EmailRow => {
    const message = composeCommercialEmail(row, cfg.appOrigin, { attachment: attached });
    return {
      id: row.email_id,
      to_address: row.recipient_address,
      from_address: row.sender_address,
      reply_to: row.reply_address,
      subject: message.subject,
      body: message.text,
      html: message.html,
      idempotency_key: row.send_key,
    };
  };

  let providerId: string;
  if (doc.ok) {
    try {
      providerId = await send(apiKey, {
        ...envelope(doc.filename),
        attachments: [{ filename: doc.filename, content: doc.base64 }],
      });
    } catch (err) {
      if (!(err instanceof PermanentSendFailure)) throw err;
      // The provider said never to the message with its attachment. Once more
      // without it, under a key of its own: the same key with a different body
      // is refused as a conflict. A message that is refused again is refused
      // for its own reasons, and fails as it always did.
      providerId = await send(apiKey, {
        ...envelope(null),
        idempotency_key: `${row.send_key}-without-attachment`,
      });
      problems.push(documentReason("the provider refused the PDF, so the email went without it", err));
    }
  } else {
    providerId = await send(apiKey, envelope(null));
  }

  let kept = false;
  if (doc.ok) {
    const problem = await keepCommercialDocument(cfg, doc.path, doc.pdf, deps.fetch);
    if (problem) problems.push(problem);
    else kept = true;
  }

  return {
    providerId,
    documentPath: doc.ok && kept ? doc.path : null,
    documentBytes: doc.ok && kept ? doc.pdf.byteLength : null,
    documentSha256: doc.ok && kept ? doc.sha256 : null,
    documentProblem: problems.length > 0 ? problems.join("; ").slice(0, 500) : null,
  };
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
      const sent = await sendCommercialEmail(row, cfg, apiKey);
      if (sent.documentProblem) {
        console.warn(`[commercial-email] ${row.email_id} (${row.email_kind}) went without a kept PDF`);
      }
      await sql.begin(
        (tx) =>
          tx`select erp.complete_commercial_email(${row.email_id}::uuid, ${sent.providerId},
                ${sent.documentPath}::text, ${sent.documentBytes}::integer,
                ${sent.documentSha256}::text, ${sent.documentProblem}::text)`,
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
