import { createFileRoute } from "@tanstack/react-router";

import { directoryHost, readDirectoryEntry } from "../../../lib/deployment-directory";

/**
 * GET /api/directory/<host>: which Supabase project a host belongs to.
 *
 * One Supabase project per client, one subdomain each. A page opened at
 * acme.cloveerp.com asks this, on its own origin, before it talks to any
 * project; the control plane's register answers through
 * public.erp_deployment_for_host, which only service_role may execute
 * (20261011020000), with what is public by design — the code, the client's
 * name, the project's API URL and its publishable key — or nothing.
 *
 * Cacheable, because a host's project does not change from one minute to the
 * next and the control plane should not be asked on every page load: five
 * minutes fresh. A brief absence of the control plane does not stop a
 * client's people signing in, because the register that cannot be read is
 * answered 503, never kept, and the browser then uses the copy it keeps for
 * a day (lookupDirectory in src/lib/erp.ts). A register that holds nothing
 * for the host is answered 404, which makes the browser forget its copy:
 * the two must never be confused, or an outage would wipe every copy kept
 * for exactly that case. The header's stale-if-error asks any cache that
 * honours it for the same grace. Not stale-while-revalidate: that served a
 * retired client's project once more to every browser that had seen it,
 * while the directory already said nothing was there. Nothing is answered
 * to a host the register does not hold, and nothing about why.
 */
const CORS = { "access-control-allow-origin": "*" };

export const Route = createFileRoute("/api/directory/$host")({
  server: {
    handlers: {
      GET: async ({ params }) => {
        const host = directoryHost(params.host);
        if (host === null) {
          return Response.json(
            { error: "not a host" },
            { status: 400, headers: { ...CORS, "cache-control": "no-store" } },
          );
        }
        const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
        const rpc = (
          supabaseAdmin.rpc as unknown as (
            n: string,
            a?: Record<string, unknown>,
          ) => Promise<{ data: unknown; error: { message: string } | null }>
        ).bind(supabaseAdmin);
        const { data, error } = await rpc("erp_deployment_for_host", { p_host: host });
        if (error) {
          // The register could not be read, which is not "nobody is here".
          return Response.json(
            { error: "the directory cannot answer just now" },
            { status: 503, headers: { ...CORS, "cache-control": "no-store" } },
          );
        }
        const entry = readDirectoryEntry(data);
        if (entry === null) {
          return Response.json(
            { error: "no deployment at this address" },
            // Briefly: a client whose build finished a minute ago should not
            // wait on a stale "nothing" for long.
            { status: 404, headers: { ...CORS, "cache-control": "public, max-age=60" } },
          );
        }
        return Response.json(entry, {
          headers: {
            ...CORS,
            "cache-control": "public, max-age=300, stale-if-error=86400",
          },
        });
      },
      OPTIONS: async () =>
        new Response(null, {
          status: 204,
          headers: { ...CORS, "access-control-allow-methods": "GET" },
        }),
    },
  },
});
