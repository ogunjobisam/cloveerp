import { createFileRoute } from "@tanstack/react-router";

import { directoryHost, directoryReply } from "../../../lib/deployment-directory";

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
 *
 * Since 20261012030000 a held host may also answer that its client's service
 * is suspended, or that the client has moved to another address; both name
 * the client and neither carries a URL or a key (readDirectoryEntry passes
 * on only what the shape it reads allows). What each answer is, status,
 * body and caching, is decided by directoryReply in
 * src/lib/deployment-directory.ts, where it is tested.
 */
const CORS = { "access-control-allow-origin": "*" };

export const Route = createFileRoute("/api/directory/$host")({
  server: {
    handlers: {
      GET: async ({ params }) => {
        const host = directoryHost(params.host);
        let register: { data: unknown; error: unknown } | null = null;
        if (host !== null) {
          const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
          const rpc = (
            supabaseAdmin.rpc as unknown as (
              n: string,
              a?: Record<string, unknown>,
            ) => Promise<{ data: unknown; error: { message: string } | null }>
          ).bind(supabaseAdmin);
          register = await rpc("erp_deployment_for_host", { p_host: host });
        }
        const reply = directoryReply(register);
        return Response.json(reply.body, {
          status: reply.status,
          headers: { ...CORS, "cache-control": reply.cacheControl },
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
