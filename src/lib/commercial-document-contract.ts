/**
 * What the commercial document function is asked, and what it answers.
 *
 * Shared by the browser (src/lib/commercial-document.functions.ts) and the
 * Edge Function that signs the link (supabase/functions/commercial_document).
 * Pure: zod and nothing else, so that Deno can follow it.
 */
import { z } from "zod";

export const COMMERCIAL_DOCUMENT_FUNCTION = "commercial_document";

export const commercialDocumentLinkInput = z.discriminatedUnion("scope", [
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

export type CommercialDocumentLinkInput = z.infer<typeof commercialDocumentLinkInput>;

export interface CommercialDocumentLink {
  signedUrl: string;
  filename: string;
  bytes: number | null;
  expiresAt: string;
}
