// The authorization UI + Supabase bridge (the OAuthProvider's defaultHandler).
//
// Flow (no redirect upstream — Supabase authenticates inline, it is not a
// third-party OAuth AS):
//   GET  /authorize  parse the OAuth request, show consent + a CloveERP sign-in form
//   POST /authorize  approve consent, sign the user in against Supabase, then
//                    completeAuthorization() storing the session in (encrypted) props
//
// The user's password is their own CloveERP credential, posted over HTTPS and
// used immediately to call Supabase — never stored (same as the app's /signin).
//
// TODO(live): the helper surface is reached here as env.OAUTH_PROVIDER (the
// single-Worker convention). Confirm the exact binding/shape against a running
// Worker before trusting the flow; the OAuth round-trip cannot be tested
// locally.
import { createClient } from "@supabase/supabase-js";
import type { OAuthHelpers } from "@cloudflare/workers-oauth-provider";

import type { ConnectorEnv, UserProps } from "./erp";

export interface Env extends ConnectorEnv {
  OAUTH_KV: KVNamespace;
  OAUTH_PROVIDER: OAuthHelpers;
}

function esc(s: string): string {
  return s.replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] ?? c,
  );
}

function page(body: string, status = 200): Response {
  return new Response(
    `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">` +
      `<title>Connect to Clove ERP</title>` +
      `<body style="font:16px system-ui;max-width:28rem;margin:3rem auto;padding:0 1rem">${body}</body>`,
    { status, headers: { "content-type": "text/html; charset=utf-8" } },
  );
}

function consentForm(clientName: string, scope: string[], handle: string, error?: string): string {
  return (
    `<h1>Connect ${esc(clientName)} to Clove ERP</h1>` +
    `<p>It will be able to: ${scope.map((s) => `<code>${esc(s)}</code>`).join(", ")}.</p>` +
    (error ? `<p style="color:#b00">${esc(error)}</p>` : "") +
    `<form method="post" action="/authorize">` +
    `<input type="hidden" name="handle" value="${esc(handle)}">` +
    `<p><label>Email<br><input name="email" type="email" required style="width:100%"></label></p>` +
    `<p><label>Password<br><input name="password" type="password" required style="width:100%"></label></p>` +
    `<p><button type="submit">Sign in and allow</button></p>` +
    `</form>`
  );
}

export const authHandler = {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const helpers = env.OAUTH_PROVIDER;

    if (url.pathname === "/authorize" && request.method === "GET") {
      const authReq = await helpers.parseAuthRequest(request);
      const client = await helpers.lookupClient(authReq.clientId);
      const { handle, headers } = await helpers.beginConsent(authReq);
      const res = page(consentForm(client?.clientName ?? authReq.clientId, authReq.scope, handle));
      for (const [k, v] of Object.entries(headers)) res.headers.append(k, v);
      return res;
    }

    if (url.pathname === "/authorize" && request.method === "POST") {
      const form = await request.formData();
      const handle = String(form.get("handle") ?? "");
      const email = String(form.get("email") ?? "");
      const password = String(form.get("password") ?? "");

      const approved = await helpers.approveConsent(request, handle, {});

      const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_PUBLISHABLE_KEY, {
        auth: { persistSession: false, autoRefreshToken: false },
      });
      const { data, error } = await supabase.auth.signInWithPassword({ email, password });
      if (error || !data.session || !data.user) {
        const client = await helpers.lookupClient(approved.request.clientId);
        return page(
          consentForm(
            client?.clientName ?? approved.request.clientId,
            approved.request.scope,
            handle,
            "That email or password was not recognised.",
          ),
          401,
        );
      }

      const props: UserProps = {
        userId: data.user.id,
        email: data.user.email ?? email,
        accessToken: data.session.access_token,
        refreshToken: data.session.refresh_token,
      };
      const { redirectTo } = await helpers.completeAuthorization({
        request: approved.request,
        userId: data.user.id,
        metadata: {},
        scope: approved.request.scope,
        props,
      });
      const res = new Response(null, { status: 302 });
      res.headers.set("location", redirectTo);
      for (const [k, v] of Object.entries(approved.headers)) res.headers.append(k, v);
      return res;
    }

    return new Response("Not found", { status: 404 });
  },
};
