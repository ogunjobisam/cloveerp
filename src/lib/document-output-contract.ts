/**
 * What the document output function is asked, and what it answers.
 *
 * Shared by the browser (src/lib/document-output.functions.ts) and the Edge
 * Function that does the work (supabase/functions/document_output), so the
 * two cannot disagree about the shape. Pure: zod and nothing else, so that
 * Deno can follow it.
 */
import { z } from "zod";

export const DOCUMENT_OUTPUT_FUNCTION = "document_output";

export const documentOutputInput = z.object({
  action: z.enum(["preview", "issue", "amend", "reprint"]),
  documentId: z.string().uuid().optional(),
  documentIssueId: z.string().uuid().optional(),
  templateVersionId: z.string().uuid().optional(),
  reason: z.string().max(400).optional(),
});

export type DocumentOutputInput = z.infer<typeof documentOutputInput>;

export interface DocumentOutputResult {
  action: string;
  issuedNumber: string | null;
  documentIssueId: string | null;
  contentChecksum: string | null;
  signedUrl: string | null;
  expiresAt: string | null;
  renderedAgain: boolean;
}
