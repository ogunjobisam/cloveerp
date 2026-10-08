/**
 * The document output door: preview, issue, amend, reprint.
 *
 * It renders; it never decides. Every decision — may this caller act, which
 * organisation is this, is the invoice legally complete, which number does it
 * take, may this file be filed against that number — is taken by a narrow
 * public routine called with the caller's own bearer token, so row-level
 * security and the permission model apply exactly as they do on a screen.
 *
 * Two clients, deliberately:
 *   - the caller's client authorises and records. It cannot write to the
 *     archive, because no browser role can.
 *   - the service client only moves bytes, and only after the caller's client
 *     has already authorised the step that needs them.
 *
 * The archive is private. A reader is handed a signed URL that lasts five
 * minutes, minted after a fresh permission check — never a public link.
 *
 * This was a TanStack server function in the application's own server until
 * 7 October (src/lib/document-output.functions.ts, which now calls this). It
 * moved here because the server holds one project's key, production's, and
 * since then every client has a project of its own: an Edge Function runs in
 * the project the page talks to, with that project's keys, and the
 * application's server holds no client's key at all.
 *
 * verify_jwt is false in supabase/config.toml because this checks its caller
 * itself against Supabase Auth, which is a stronger test than the gateway's
 * (the anon key is a valid JWT and would pass it), and then calls every door
 * as that person.
 */
import { createClient, type SupabaseClient } from "@supabase/supabase-js";

import {
  documentOutputInput,
  type DocumentOutputInput,
  type DocumentOutputResult,
} from "../../../src/lib/document-output-contract.ts";
import {
  renderSalesInvoicePdf,
  sha256Blob,
  sha256Hex,
  type InvoiceContract,
} from "../../../src/lib/pdf/invoice-pdf.ts";
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
const PREVIEW_MINUTES = 15;

type Rpc = <T = unknown>(
  name: string,
  args?: Record<string, unknown>,
) => Promise<{ data: T; error: { message: string } | null }>;

function rpcOf(client: SupabaseClient): Rpc {
  return <T = unknown>(name: string, args?: Record<string, unknown>) =>
    (
      client.rpc as unknown as (
        n: string,
        a?: Record<string, unknown>,
      ) => Promise<{ data: T; error: { message: string } | null }>
    )(name, args);
}

async function documentOutput(
  data: DocumentOutputInput,
  caller: SupabaseClient,
  admin: SupabaseClient,
): Promise<DocumentOutputResult> {
  const rpc = rpcOf(caller);
  const archive = admin.storage.from(BUCKET);

  if (data.action === "preview") {
    if (!data.documentId) refuse("Choose an invoice to preview against.");

    // Abandoned previews are swept whenever a new one is made, so a screen
    // nobody came back to does not leave a file for somebody to find later.
    // The door asks for document.template_manage, which making a preview
    // needs too; the worker sweeps for everybody else on its own schedule.
    const swept = await rpc<{ storage_paths?: string[] } | null>(
      "erp_purge_expired_document_previews",
    );
    const stale = (swept.data?.storage_paths ?? []) as string[];
    if (stale.length > 0) await archive.remove(stale);

    // Reading the contract is gated on the invoice's own read permission;
    // registering the preview additionally needs template management.
    const contract = await rpc<InvoiceContract>("erp_sales_invoice_contract", {
      p_document_id: data.documentId,
    });
    if (contract.error) refuse(contract.error.message);

    const session = await rpc<{ tenant_id?: string } | null>("erp_session");
    const tenant = String(session.data?.tenant_id ?? "");
    if (!tenant) refuse("No organisation is in scope.");

    const bytes = await renderSalesInvoicePdf(contract.data as InvoiceContract, {
      watermark: "PREVIEW",
    });
    const checksum = await sha256Hex(bytes);
    const path = `${tenant}/previews/${crypto.randomUUID()}.pdf`;

    const uploaded = await archive.upload(path, bytes, { contentType: "application/pdf" });
    if (uploaded.error) refuse(uploaded.error.message);

    const recorded = await rpc<{ expires_at?: string } | null>("erp_record_document_preview", {
      p_document_id: data.documentId,
      p_template_version_id: data.templateVersionId ?? null,
      p_storage_path: path,
      p_content_checksum: checksum,
      p_minutes: PREVIEW_MINUTES,
    });
    if (recorded.error) {
      await archive.remove([path]);
      refuse(recorded.error.message);
    }

    const signed = await archive.createSignedUrl(path, SIGNED_URL_SECONDS);
    return {
      action: "preview",
      issuedNumber: null,
      documentIssueId: null,
      contentChecksum: checksum,
      signedUrl: signed.data?.signedUrl ?? null,
      expiresAt: (recorded.data?.expires_at as string | undefined) ?? null,
      renderedAgain: true,
    };
  }

  if (data.action === "issue" || data.action === "amend") {
    // The number and the frozen contract come first. An invoice that is not
    // legally complete is refused here, before anything is rendered or
    // stored, and the refusal names the field.
    const reserved =
      data.action === "issue"
        ? await rpc<{ document_issue_id?: string; issued_number?: string } | null>(
            "erp_issue_sales_invoice",
            {
              p_document_id: data.documentId,
              p_template_version_id: data.templateVersionId ?? null,
            },
          )
        : await rpc<{ document_issue_id?: string; issued_number?: string } | null>(
            "erp_amend_sales_invoice",
            {
              p_document_issue_id: data.documentIssueId,
              p_reason: data.reason ?? "Amended before sending",
            },
          );
    if (reserved.error) refuse(reserved.error.message);
    const issueId = String(reserved.data?.document_issue_id ?? "");
    const issuedNumber = String(reserved.data?.issued_number ?? "");

    // Whatever fails between taking the number and filing the PDF voids the
    // number (20260923500000). The press has already moved the invoice to
    // Issued and posted it, and a number held with no PDF behind it left the
    // invoice with no way on: pressed again it is numbered afresh.
    let voided = false;
    let path = "";
    let storedHash = "";
    try {
      const session = await rpc<{ tenant_id?: string } | null>("erp_session");
      const tenant = String(session.data?.tenant_id ?? "");

      // Render from the frozen contract that was just written, not from the
      // live records: what is printed is what was issued.
      const issues = await rpc<Array<Record<string, unknown>>>("erp_document_issues", {
        p_document_id: null,
        p_limit: 200,
      });
      if (issues.error) refuse(issues.error.message);
      const row = issues.data.find((i) => i["document_issue_id"] === issueId);
      if (!row?.["contract_snapshot"]) refuse("The frozen contract could not be read back.");

      const bytes = await renderSalesInvoicePdf(row["contract_snapshot"] as never, {
        issuedNumber,
      });
      path = `${tenant}/${issuedNumber}.pdf`;
      const checksum = await sha256Hex(bytes);

      const uploaded = await archive.upload(path, bytes, {
        contentType: "application/pdf",
        upsert: false,
        metadata: { sha256: checksum },
      });
      if (uploaded.error) refuse(uploaded.error.message);

      // The checksum filed is the hash of what the archive actually holds,
      // read back rather than assumed. The database checks it again against
      // the stored object before it will accept the number as issued.
      const stored = await archive.download(path);
      if (stored.error || !stored.data) refuse("The stored file could not be read back.");
      storedHash = await sha256Blob(stored.data);

      const completed = await rpc("erp_complete_document_issue", {
        p_document_issue_id: issueId,
        p_storage_path: path,
        p_content_checksum: storedHash,
      });
      if (completed.error) {
        await archive.remove([path]);
        const failed = await rpc("erp_fail_document_issue", {
          p_document_issue_id: issueId,
          p_reason: `Rendering completed but archive verification failed: ${completed.error.message}`,
        });
        voided = true;
        if (failed.error) {
          refuse(
            `${completed.error.message}; the spent number could not be marked void: ${failed.error.message}`,
          );
        }
        refuse(completed.error.message);
      }
    } catch (error) {
      if (!voided && issueId !== "") {
        const message = error instanceof Error ? error.message : String(error);
        if (path !== "") await archive.remove([path]);
        await rpc("erp_fail_document_issue", {
          p_document_issue_id: issueId,
          p_reason: `The PDF was not filed: ${message}`,
        });
      }
      throw error;
    }

    const signed = await archive.createSignedUrl(path, SIGNED_URL_SECONDS);
    return {
      action: data.action,
      issuedNumber,
      documentIssueId: issueId,
      contentChecksum: storedHash,
      signedUrl: signed.data?.signedUrl ?? null,
      expiresAt: null,
      renderedAgain: true,
    };
  }

  // Reprint: nothing is rendered and no number moves. The bytes that were
  // issued are the bytes that come back, checked against their checksum.
  if (!data.documentIssueId) refuse("Choose an issued document to reprint.");
  const reprint = await rpc<{
    storage_path?: string;
    content_checksum?: string;
    issued_number?: string;
  } | null>("erp_reprint_document_issue", {
    p_document_issue_id: data.documentIssueId,
    p_reason: data.reason ?? null,
  });
  if (reprint.error) refuse(reprint.error.message);

  const storedPath = String(reprint.data?.storage_path ?? "");
  const stored = await archive.download(storedPath);
  if (stored.error || !stored.data) {
    refuse(
      "CLOVEERP_DOCUMENT_OBJECT_MISSING: the issued file is not in the archive, so it cannot be reprinted.",
    );
  }
  const hash = await sha256Blob(stored.data);
  if (hash !== reprint.data?.content_checksum) {
    refuse(
      "CLOVEERP_DOCUMENT_CHECKSUM_MISMATCH: the archived file no longer matches the document that was issued.",
    );
  }

  const signed = await archive.createSignedUrl(storedPath, SIGNED_URL_SECONDS);
  return {
    action: "reprint",
    issuedNumber: String(reprint.data?.issued_number ?? ""),
    documentIssueId: data.documentIssueId,
    contentChecksum: hash,
    signedUrl: signed.data?.signedUrl ?? null,
    expiresAt: null,
    renderedAgain: false,
  };
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(req) });
  if (req.method !== "POST") return reply(req, 405, { error: "POST only" });
  try {
    const { url, anonKey, serviceKey } = project();
    const bearer = bearerOf(req);
    const userId = bearer ? await signedIn(url, anonKey, bearer) : null;
    if (!bearer || !userId) return reply(req, 401, { error: "Sign in first." });

    const parsed = documentOutputInput.safeParse(await jsonBody(req));
    if (!parsed.success) {
      return reply(req, 400, {
        error: parsed.error.issues[0]?.message ?? "The request is not understood.",
      });
    }

    // The caller's own token on every door, so the database decides as the
    // caller; the service key only moves bytes.
    const caller = createClient(url, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { authorization: `Bearer ${bearer}` } },
    });
    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const result = await documentOutput(parsed.data, caller, admin);
    return reply(req, 200, result);
  } catch (error) {
    return failure(req, error);
  }
});
