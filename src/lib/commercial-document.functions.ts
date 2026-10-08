/**
 * A short link to the PDF of an order form or contract invoice that was sent,
 * from the browser.
 *
 * The Edge Function supabase/functions/commercial_document asks the database,
 * as the caller, whether this caller may have the document and where it is,
 * and only then signs a link that lasts five minutes, in the project this
 * page talks to and with that project's keys. A TanStack server function
 * until 7 October; moved for the reason src/lib/document-output.functions.ts
 * gives.
 */
import { callFunction } from "./erp";
import {
  COMMERCIAL_DOCUMENT_FUNCTION,
  type CommercialDocumentLink,
  type CommercialDocumentLinkInput,
} from "./commercial-document-contract";

export type {
  CommercialDocumentLink,
  CommercialDocumentLinkInput,
} from "./commercial-document-contract";

export function commercialDocumentLink({
  data,
}: {
  data: CommercialDocumentLinkInput;
}): Promise<CommercialDocumentLink> {
  return callFunction<CommercialDocumentLink>(COMMERCIAL_DOCUMENT_FUNCTION, data);
}
