/**
 * The organisation an address names, asked on the server.
 *
 * The sign-in form at /<code> is shown to somebody who is not signed in, and
 * anon may execute no erp_* door: erp.public_api_report() refuses one, with no
 * register to excuse it. So the browser does not ask. This server function
 * does, with the service client, and public.erp_tenant_by_address — which only
 * service_role may execute — answers the organisation's current code and name,
 * or nothing. Nothing else passes back to the browser.
 */
import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";

import { ADDRESS_MAX, readAddressLookup, type AddressLookup } from "./tenant-address";

const input = z.object({ code: z.string().min(1).max(ADDRESS_MAX) });

export const tenantByAddress = createServerFn({ method: "GET" })
  .inputValidator((data: unknown) => input.parse(data))
  .handler(async ({ data }): Promise<AddressLookup | null> => {
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
