/**
 * The document output door, from the browser: preview, issue, amend, reprint.
 *
 * The work — rendering the PDF from the frozen contract, filing it in the
 * private archive, reading it back, minting a five-minute link — is done by
 * the Edge Function supabase/functions/document_output, in the project this
 * page talks to and with that project's keys. It was a TanStack server
 * function in the application's own server until 7 October; the server holds
 * one project's key, production's, and since then every client has a project
 * of its own (src/lib/backend.ts).
 *
 * Called the way it always was, so the screens did not change: the session's
 * bearer goes with the request (functions.invoke attaches it), the function
 * calls every door as that person, and a refusal comes back as an ErpError
 * carrying the database's own code and words.
 */
import { callFunction } from "./erp";
import {
  DOCUMENT_OUTPUT_FUNCTION,
  type DocumentOutputInput,
  type DocumentOutputResult,
} from "./document-output-contract";

export type { DocumentOutputResult } from "./document-output-contract";

export function documentOutput({
  data,
}: {
  data: DocumentOutputInput;
}): Promise<DocumentOutputResult> {
  return callFunction<DocumentOutputResult>(DOCUMENT_OUTPUT_FUNCTION, data);
}
