/**
 * A short link to the PDF of an order form or contract invoice that was sent.
 *
 * The dispatch drain attaches the PDF to the email and keeps a copy in the
 * private document-output bucket (20260915020000). This hands a reader a
 * signed link to that copy, the way document_output hands one to an issued
 * sales invoice: the caller's own token asks the database whether this caller
 * may have it and where it is, and only then does the service client sign a
 * link that lasts five minutes. Nothing is decided here.
 *
 *   - A customer's administrator asks by the document: the order form or the
 *     invoice id. public.erp_my_commercial_document() answers only for the
 *     caller's own organisation and refuses anything else as not found.
 *   - Platform staff ask by the send: public.erp_platform_commercial_document()
 *     answers for support and above.
 *
 * A TanStack server function until 7 October (src/lib/commercial-document.
 * functions.ts, which now calls this); moved here so that it runs in the
 * project the page talks to, with that project's keys, since every client
 * has a project of its own.
 */
import { createClient } from "@supabase/supabase-js";

import {
  commercialDocumentLinkInput,
  type CommercialDocumentLink,
} from "../../../src/lib/commercial-document-contract.ts";
import {
  bearerOf,
  cors,
  failure,
  jsonBody,
  project,
  refuse,
  reply,
  signedIn,
} from "../_shared/caller.ts";

// deno-lint-ignore no-explicit-any
const Deno = (globalThis as any).Deno;

const BUCKET = "document-output";
const SIGNED_URL_SECONDS = 300;

type Stored = { storage_path?: string; filename?: string; bytes?: number | null };

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(req) });
  if (req.method !== "POST") return reply(req, 405, { error: "POST only" });
  try {
    const { url, anonKey, serviceKey } = project();
    const bearer = bearerOf(req);
    const userId = bearer ? await signedIn(url, anonKey, bearer) : null;
    if (!bearer || !userId) return reply(req, 401, { error: "Sign in first." });

    const parsed = commercialDocumentLinkInput.safeParse(await jsonBody(req));
    if (!parsed.success) {
      return reply(req, 400, {
        error: parsed.error.issues[0]?.message ?? "The request is not understood.",
      });
    }
    const data = parsed.data;

    // The caller's token first, so the database decides as the caller.
    const caller = createClient(url, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { authorization: `Bearer ${bearer}` } },
    });
    const rpc = (
      caller.rpc as unknown as (
        n: string,
        a?: Record<string, unknown>,
      ) => Promise<{ data: Stored | null; error: { message: string } | null }>
    ).bind(caller);

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

    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const signed = await admin.storage
      .from(BUCKET)
      .createSignedUrl(path, SIGNED_URL_SECONDS, { download: filename });
    if (signed.error || !signed.data?.signedUrl) {
      refuse("The stored copy could not be opened. Ask Clove ERP to send the document again.");
    }
    const link: CommercialDocumentLink = {
      signedUrl: signed.data.signedUrl,
      filename,
      bytes: found.data?.bytes ?? null,
      expiresAt: new Date(Date.now() + SIGNED_URL_SECONDS * 1000).toISOString(),
    };
    return reply(req, 200, link);
  } catch (error) {
    return failure(req, error);
  }
});
