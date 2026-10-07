/**
 * A supplier's answer to a purchase order, asked and given on their behalf
 * (20261004990000, 20261005000000).
 *
 * The supplier is no principal and has no organisation: the link in the PO
 * email is their authority, and anon may execute no erp_* door. So the browser
 * does not ask. This function does, with the service client, and only
 * service_role may execute public.erp_supplier_response_peek,
 * public.erp_supplier_respond and public.erp_supplier_notify_shipment. Every
 * request is a POST, so the token travels in a body and never in a query
 * string a log would keep.
 *
 * Three TanStack server functions until 7 October (src/lib/supplier-response.
 * functions.ts, which now calls this); moved here so that a supplier's link
 * to a client's order is answered by that client's own project, since every
 * client has a project of its own and the application's server holds no
 * client's key.
 *
 * verify_jwt is false in supabase/config.toml: the supplier has no session,
 * and the token the link carries is what the database checks.
 */
import { createClient } from "@supabase/supabase-js";

import {
  refusalWords,
  supplierRequest,
  type SupplierRespondResult,
} from "../../../src/lib/supplier-response-contract.ts";
import { cors, failure, jsonBody, project, reply } from "../_shared/caller.ts";

// deno-lint-ignore no-explicit-any
const Deno = (globalThis as any).Deno;

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(req) });
  if (req.method !== "POST") return reply(req, 405, { error: "POST only" });
  try {
    const { url, serviceKey } = project();
    const parsed = supplierRequest.safeParse(await jsonBody(req));
    if (!parsed.success) {
      return reply(req, 400, {
        error: parsed.error.issues[0]?.message ?? "The request is not understood.",
      });
    }
    const data = parsed.data;

    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const rpc = (
      admin.rpc as unknown as (
        n: string,
        a?: Record<string, unknown>,
      ) => Promise<{ data: unknown; error: { message: string } | null }>
    ).bind(admin);

    if (data.action === "peek") {
      // The order a link names, or null: a wrong or old link learns nothing.
      const { data: order, error } = await rpc("erp_supplier_response_peek", {
        p_token: data.token,
      });
      return reply(req, 200, { order: error ? null : order });
    }

    let result: SupplierRespondResult;
    if (data.action === "respond") {
      const { error } = await rpc("erp_supplier_respond", {
        p_token: data.token,
        p_response: data.answer,
      });
      result = error
        ? { ok: false, message: refusalWords(error.message, "The answer could not be recorded.") }
        : { ok: true };
    } else {
      const { error } = await rpc("erp_supplier_notify_shipment", {
        p_token: data.token,
        p_notice: data.notice,
      });
      result = error
        ? { ok: false, message: refusalWords(error.message, "The notice could not be recorded.") }
        : { ok: true };
    }
    return reply(req, 200, result);
  } catch (error) {
    return failure(req, error);
  }
});
