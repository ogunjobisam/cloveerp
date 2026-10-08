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
 * The service client is production's, the control plane's: the server holds
 * no other project's key. So on demo.cloveerp.com, where the page talks to the
 * demonstration project (./backend.ts), and on a client's own host, an address
 * answers nothing rather than naming a production organisation on another
 * deployment's sign-in screen.
 *
 * Since 20261011020000 the control plane also keeps the register of client
 * deployments, and an address that names one answers with where that client
 * lives — its own origin, <code>.cloveerp.com — so cloveerp.com/acme takes
 * Acme's people to Acme's own door.
 *
 * Since 20261012020000 the register matches a client by its address, which a
 * rename changes while its code stays: the origin is the address asked about,
 * never built from the register's code, and an address the client has moved
 * from sends the visitor straight to the new one. A suspended client's
 * address still answers, and its own door says it is suspended.
 */
import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";

import { APEX_HOST, DEMO_HOST, isDirectoryHost, normalHost } from "./backend";
import { readDirectoryEntry } from "./deployment-directory";
import { requestHost } from "./request-host";
import { ADDRESS_MAX, readAddressLookup, type AddressLookup } from "./tenant-address";

const input = z.object({ code: z.string().min(1).max(ADDRESS_MAX) });

export const tenantByAddress = createServerFn({ method: "GET" })
  .inputValidator((data: unknown) => input.parse(data))
  .handler(async ({ data }): Promise<AddressLookup | null> => {
    const { getRequest } = await import("@tanstack/react-start/server");
    const host = requestHost(getRequest());
    // Every name under the apex but the apex and www is another deployment's,
    // or nobody's, whatever its shape (isDirectoryHost).
    if (normalHost(host) === DEMO_HOST || isDirectoryHost(host)) return null;
    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
    const rpc = (
      supabaseAdmin.rpc as unknown as (
        n: string,
        a?: Record<string, unknown>,
      ) => Promise<{ data: unknown; error: { message: string } | null }>
    ).bind(supabaseAdmin);
    const code = data.code.trim().toLowerCase();
    // A client deployment's address first: the organisation is on its own
    // project, and the visitor is sent there. A database older than the
    // register answers an error here, which reads as "not a deployment".
    const deployment = await rpc("erp_deployment_for_host", { p_host: `${code}.${APEX_HOST}` });
    const entry = deployment.error ? null : readDirectoryEntry(deployment.data);
    if (entry) {
      return {
        code,
        name: entry.client_name,
        origin: "moved_to" in entry ? entry.moved_to : `https://${code}.${APEX_HOST}`,
      };
    }
    const { data: answer, error } = await rpc("erp_tenant_by_address", { p_code: data.code });
    // A visitor is told nothing about why: an address that could not be
    // looked up reads the same as one nobody holds.
    if (error) return null;
    return readAddressLookup(answer);
  });
