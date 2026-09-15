/**
 * A short link to the PDF of an order form or contract invoice that was sent.
 *
 * The dispatch drain attaches the PDF to the email and keeps a copy in the
 * private document-output bucket (20260915020000). This hands a reader a
 * signed link to that copy, the way document-output.functions.ts hands one to
 * an issued sales invoice: the caller's own token asks the database whether
 * this caller may have it and where it is, and only then does the service
 * client sign a link that lasts five minutes. Nothing is decided here.
 *
 *   - A customer's administrator asks by the document: the order form or the
 *     invoice id. public.erp_my_commercial_document() answers only for the
 *     caller's own organisation and refuses anything else as not found.
 *   - Platform staff ask by the send: public.erp_platform_commercial_document()
 *     answers for support and above.
 */
import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import { attachErpSession } from "./erp-session-middleware";

const BUCKET = "document-output";
const SIGNED_URL_SECONDS = 300;

const input = z.discriminatedUnion("scope", [
  z.object({
    scope: z.literal("mine"),
    kind: z.enum(["order_form", "contract_invoice"]),
    documentId: z.string().uuid(),
  }),
  z.object({
    scope: z.literal("platform"),
    emailId: z.string().uuid(),
  }),
]);

export type CommercialDocumentLinkInput = z.infer<typeof input>;

export interface CommercialDocumentLink {
  signedUrl: string;
  filename: string;
  bytes: number | null;
  expiresAt: string;
}

type Stored = { storage_path?: string; filename?: string; bytes?: number | null };

/** A refusal from the database is already plain language; keep its code. */
function refuse(message: string): never {
  const match = /(CLOVEERP_[A-Z_]+)\s*:?\s*(.*)/.exec(message);
  throw new Error(match ? `${match[1]}: ${(match[2] ?? "").trim() || message}` : message);
}

export const commercialDocumentLink = createServerFn({ method: "POST" })
  // The caller's token first, so the database decides as the caller.
  .middleware([attachErpSession, requireSupabaseAuth])
  .inputValidator((data: unknown) => input.parse(data))
  .handler(async ({ data, context }): Promise<CommercialDocumentLink> => {
    const rpc = (
      context.supabase.rpc as unknown as (
        n: string,
        a?: Record<string, unknown>,
      ) => Promise<{ data: Stored | null; error: { message: string } | null }>
    ).bind(context.supabase);

    const found =
      data.scope === "mine"
        ? await rpc("erp_my_commercial_document", {
            p_kind: data.kind,
            p_document_id: data.documentId,
          })
        : await rpc("erp_platform_commercial_document", { p_email_id: data.emailId });
    if (found.error) refuse(found.error.message);
    const path = found.data?.storage_path;
    const filename = found.data?.filename;
    if (!path || !filename) refuse("The document's stored copy could not be found.");

    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
    const signed = await supabaseAdmin.storage
      .from(BUCKET)
      .createSignedUrl(path, SIGNED_URL_SECONDS, { download: filename });
    if (signed.error || !signed.data?.signedUrl) {
      refuse("The stored copy could not be opened. Ask Clove ERP to send the document again.");
    }
    return {
      signedUrl: signed.data.signedUrl,
      filename,
      bytes: found.data?.bytes ?? null,
      expiresAt: new Date(Date.now() + SIGNED_URL_SECONDS * 1000).toISOString(),
    };
  });
