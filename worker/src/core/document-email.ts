import {
  DocumentEmailError,
  composePurchaseOrderEmail,
  namedSender,
  type ClaimedDocumentEmail,
} from "../../../src/lib/email/purchase-order-email.ts";
import { documentReason, keepCommercialDocument } from "./commercial.ts";
import type { TenantBinding, WorkerConfig } from "./config.ts";
import { asPrincipal, type Sql } from "./db.ts";
import { PermanentSendFailure, sendViaResend, type EmailRow } from "./resend.ts";

/**
 * The documents an organisation sends outside itself (20261004920000): a
 * purchase order to its supplier, queued in erp.document_email by
 * erp_send_purchase_order, one row per send.
 *
 * Shaped as drainCommercialEmail is, but per organisation, as drainEmail is:
 * claim a batch as the organisation's principal, render the PDF from the
 * payload the order's issue froze, send it attached, keep a copy in the
 * document-output bucket, and settle each row on its own. A document that
 * cannot be made, a provider that refuses the attachment, or a copy that cannot
 * be kept is a reason recorded on the row, and the email still goes, saying
 * plainly that no PDF is attached. A payload that cannot be made into an email
 * is failed for good; a provider's "never" is failed for good; anything else is
 * tried again, five times in all. Every message carries the row's idempotency
 * key, so one whose settle was lost after the provider took it is not
 * delivered twice when its lease runs out.
 *
 * The log names ids only: a payload holds names, addresses and prices.
 */

export type DocumentEmailCounts = {
  documentEmailClaimed: number;
  documentEmailSent: number;
  documentEmailFailed: number;
};

/** Up to this many an organisation a pass. */
export const DOCUMENT_EMAIL_BATCH = 20;

type Renderer = typeof import("../../../src/lib/pdf/purchase-order-pdf.ts");
type Kit = typeof import("../../../src/lib/pdf/commercial-document.ts");

let rendererLoad: Promise<{ po: Renderer; kit: Kit }> | null = null;

/**
 * The renderer, loaded the first time a document is wanted, as commercial.ts
 * loads its own, so a runtime that cannot resolve pdf-lib still sends email.
 */
export function loadPurchaseOrderRenderer(): Promise<{ po: Renderer; kit: Kit }> {
  rendererLoad ??= Promise.all([
    import("../../../src/lib/pdf/purchase-order-pdf.ts"),
    import("../../../src/lib/pdf/commercial-document.ts"),
  ])
    .then(([po, kit]) => ({ po, kit }))
    .catch((err: unknown) => {
      rendererLoad = null;
      throw err;
    });
  return rendererLoad;
}

/** Whether a failure should be tried again on a later pass. */
export function worthRetryingDocument(err: unknown): boolean {
  return !(err instanceof PermanentSendFailure || err instanceof DocumentEmailError);
}

export type MadePurchaseOrder =
  | { ok: true; filename: string; path: string; pdf: Uint8Array; sha256: string; base64: string }
  | { ok: false; problem: string };

/** The PDF for one claimed row. Never throws: a document that cannot be made says why. */
export async function makePurchaseOrderDocument(
  row: Pick<ClaimedDocumentEmail, "id" | "payload">,
  load: () => Promise<{ po: Renderer; kit: Kit }> = loadPurchaseOrderRenderer,
): Promise<MadePurchaseOrder> {
  try {
    const { po, kit } = await load();
    const pdf = await po.renderPurchaseOrderPdf(row.payload);
    return {
      ok: true,
      filename: po.purchaseOrderFilename(row.payload),
      path: po.purchaseOrderPath(row.id),
      pdf,
      sha256: await kit.sha256Hex(pdf),
      base64: kit.pdfToBase64(pdf),
    };
  } catch (err) {
    return {
      ok: false,
      problem: documentReason("no PDF could be made, so the email went without one", err),
    };
  }
}

export type SentDocumentEmail = {
  providerId: string;
  documentPath: string | null;
  documentBytes: number | null;
  documentSha256: string | null;
  documentProblem: string | null;
};

type Send = (apiKey: string, row: EmailRow) => Promise<string>;
type Fetch = (input: string, init: RequestInit) => Promise<Response>;

/**
 * Make the document, send the message with it, and keep the copy: everything
 * one row needs before its settle. Throws only what the email itself throws,
 * so the caller fails the row as drainEmail fails a notification.
 */
export async function sendDocumentEmail(
  row: ClaimedDocumentEmail,
  cfg: Pick<WorkerConfig, "supabaseUrl" | "supabaseServiceRoleKey" | "httpTimeoutMs" | "appOrigin">,
  apiKey: string,
  deps: { send?: Send; fetch?: Fetch; load?: () => Promise<{ po: Renderer; kit: Kit }> } = {},
): Promise<SentDocumentEmail> {
  const send = deps.send ?? sendViaResend;
  // An email that cannot be written fails before any document is made.
  composePurchaseOrderEmail(row, { appOrigin: cfg.appOrigin });

  const doc = await makePurchaseOrderDocument(row, deps.load);
  const problems: string[] = doc.ok ? [] : [doc.problem];

  const envelope = (attached: string | null): EmailRow => {
    // The supplier's "Confirm this order" link (20261004990000).
    const message = composePurchaseOrderEmail(row, {
      attachment: attached,
      appOrigin: cfg.appOrigin,
    });
    return {
      id: row.id,
      to_address: row.to_address,
      cc: row.cc_addresses ?? [],
      from_address: namedSender(row.from_name, row.from_address),
      reply_to: row.reply_to,
      subject: message.subject,
      body: message.text,
      html: message.html,
      idempotency_key: row.idempotency_key,
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
      // Refused with the attachment: once more without it, under a key of its
      // own, as commercial.ts does.
      providerId = await send(apiKey, {
        ...envelope(null),
        idempotency_key: `${row.idempotency_key}-without-attachment`,
      });
      problems.push(
        documentReason("the provider refused the PDF, so the email went without it", err),
      );
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

/** One pass over one organisation's outgoing documents. */
export async function drainDocumentEmail(
  sql: Sql,
  b: TenantBinding,
  cfg: WorkerConfig,
  out: DocumentEmailCounts,
): Promise<void> {
  const apiKey = cfg.resendApiKey;
  if (!apiKey) return;

  const claimed = (await asPrincipal(
    sql,
    b,
    (tx) =>
      tx`select * from erp.claim_document_email_batch(${DOCUMENT_EMAIL_BATCH}, ${cfg.workerName})`,
  )) as unknown as ClaimedDocumentEmail[];

  if (claimed.length === 0) return;
  out.documentEmailClaimed += claimed.length;

  for (const row of claimed) {
    try {
      const sent = await sendDocumentEmail(row, cfg, apiKey);
      if (sent.documentProblem) {
        console.warn(`[document-email] ${row.id} (${row.document_kind}) went without a kept PDF`);
      }
      await asPrincipal(
        sql,
        b,
        (tx) =>
          tx`select erp.complete_document_email(${row.id}::uuid, ${sent.providerId},
                ${sent.documentPath}::text, ${sent.documentBytes}::integer,
                ${sent.documentSha256}::text, ${sent.documentProblem}::text)`,
      );
      out.documentEmailSent += 1;
    } catch (err) {
      const retry = worthRetryingDocument(err);
      console.warn(
        `[document-email] ${row.id} (${row.document_kind}) was not sent; ${retry ? "it will be tried again" : "it is failed"}`,
      );
      await asPrincipal(
        sql,
        b,
        (tx) =>
          tx`select erp.fail_document_email(${row.id}::uuid, ${String((err as Error).message)}, ${retry})`,
      );
      out.documentEmailFailed += 1;
    }
  }
}
