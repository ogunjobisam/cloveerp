/**
 * The organisation an address names, asked on the server.
 *
 * The sign-in form at /<code> is shown to somebody who is not signed in, and
 * anon may execute no erp_* door: erp.public_api_report() refuses one, with no
 * register to excuse it. So the browser does not ask. This server function
 * does, with the service client, and public.erp_tenant_by_address — which only
 * service_role may execute — answers the organisation's current code and name,
 * or nothing. Nothing else passes back to the browser.
 *
 * The service client is production's: the server holds no other project's
 * key. So on demo.cloveerp.com, where the page talks to the demonstration
 * project (./backend.ts), an address answers nothing rather than naming a
 * production organisation on the demonstration's sign-in screen.
 */
import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";

import { DEMO_HOST } from "./backend";
import { ADDRESS_MAX, readAddressLookup, type AddressLookup } from "./tenant-address";

/** The host a request was made to, without its port, as the visitor typed it. */
function requestHost(request: Request): string {
  const named =
    request.headers.get("x-forwarded-host") ??
    request.headers.get("host") ??
    new URL(request.url).host;
  return (named.split(",")[0] ?? "").trim().split(":")[0]?.toLowerCase() ?? "";
}

const input = z.object({ code: z.string().min(1).max(ADDRESS_MAX) });

export const tenantByAddress = createServerFn({ method: "GET" })
  .inputValidator((data: unknown) => input.parse(data))
  .handler(async ({ data }): Promise<AddressLookup | null> => {
    const { getRequest } = await import("@tanstack/react-start/server");
    if (requestHost(getRequest()) === DEMO_HOST) return null;
    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
    const rpc = (
      supabaseAdmin.rpc as unknown as (
        n: string,
        a?: Record<string, unknown>,
      ) => Promise<{ data: unknown; error: { message: string } | null }>
    ).bind(supabaseAdmin);
    const { data: answer, error } = await rpc("erp_tenant_by_address", { p_code: data.code });
    // A visitor is told nothing about why: an address that could not be
    // looked up reads the same as one nobody holds.
    if (error) return null;
    return readAddressLookup(answer);
  });
