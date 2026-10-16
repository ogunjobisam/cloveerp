// The CloveERP MCP connector Worker entry.
//
// OAuthProvider makes this Worker an OAuth 2.1 provider and routes:
//   - /mcp           → the MCP endpoint (apiHandler), requiring a valid token
//   - everything else → the authorization UI + Supabase bridge (defaultHandler)
//
// Grants/tokens live in OAUTH_KV (hashed; props encrypted). On refresh,
// tokenExchangeCallback refreshes the Supabase session so the stored access
// token the tools use stays valid.
//
// TODO(live): this cannot be exercised without deploying to Cloudflare with
// OAUTH_KV + the Supabase vars set. See mcp/README.md for the deploy
// prerequisites and the security review that a new public auth surface needs.
import OAuthProvider from "@cloudflare/workers-oauth-provider";
import { createClient } from "@supabase/supabase-js";

import { authHandler, type Env } from "./auth";
import { mcpHandler } from "./mcp-server";
import type { UserProps } from "./erp";

export default new OAuthProvider<Env>({
  apiRoute: "/mcp",
  apiHandler: {
    // The stateless MCP handler is callable as (request, env, ctx).
    fetch(request: Request, env: Env, ctx: ExecutionContext) {
      return mcpHandler(env)(request, env, ctx);
    },
  },
  defaultHandler: authHandler,
  authorizeEndpoint: "/authorize",
  tokenEndpoint: "/token",
  scopesSupported: ["mcp:read"],
  requiredScopes: ["mcp:read"],
  resourceMetadata: {
    // The connector's public URL; set when the subdomain is reserved.
    resource: "https://mcp.cloveerp.com/mcp",
    authorization_servers: ["https://mcp.cloveerp.com"],
  },
  // Keep the stored Supabase session fresh when the MCP client refreshes.
  tokenExchangeCallback: async (options) => {
    const props = options.props as UserProps;
    const supabase = createClient(
      // These come from env at runtime; the callback receives them via closure
      // when wired to the Worker env. TODO(live): thread env into this callback.
      props["supabaseUrl"] as string,
      props["supabasePublishableKey"] as string,
      { auth: { persistSession: false, autoRefreshToken: false } },
    );
    const { data } = await supabase.auth.refreshSession({ refresh_token: props.refreshToken });
    if (!data.session) return undefined;
    return {
      newProps: {
        ...props,
        accessToken: data.session.access_token,
        refreshToken: data.session.refresh_token,
      },
    };
  },
});
