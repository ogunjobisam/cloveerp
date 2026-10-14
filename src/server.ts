import "./lib/error-capture";

import { AsyncLocalStorage } from "node:async_hooks";

import { consumeLastCapturedError } from "./lib/error-capture";
import { renderErrorPage } from "./lib/error-page";
import { CSP_REPORT_PATH, contentSecurityPolicy, newNonce } from "./lib/content-security-policy";
import { withSecurityHeaders } from "./lib/security-headers";

type ServerEntry = {
  fetch: (request: Request, env: unknown, ctx: unknown) => Promise<Response> | Response;
};

let serverEntryPromise: Promise<ServerEntry> | undefined;

async function getServerEntry(): Promise<ServerEntry> {
  if (!serverEntryPromise) {
    serverEntryPromise = import("@tanstack/react-start/server-entry").then(
      (m) => (m.default ?? m) as ServerEntry,
    );
  }
  return serverEntryPromise;
}

// h3 swallows in-handler throws into a normal 500 Response with body
// {"unhandled":true,"message":"HTTPError"} — try/catch alone never fires for those.
async function normalizeCatastrophicSsrResponse(response: Response): Promise<Response> {
  if (response.status < 500) return response;
  const contentType = response.headers.get("content-type") ?? "";
  if (!contentType.includes("application/json")) return response;

  const body = await response.clone().text();
  if (!isH3SwallowedErrorBody(body)) return response;

  console.error(consumeLastCapturedError() ?? new Error(`h3 swallowed SSR error: ${body}`));
  return new Response(renderErrorPage(), {
    status: 500,
    headers: { "content-type": "text/html; charset=utf-8" },
  });
}

function isH3SwallowedErrorBody(body: string): boolean {
  try {
    const payload = JSON.parse(body) as { unhandled?: unknown; message?: unknown };
    return payload.unhandled === true && payload.message === "HTTPError";
  } catch {
    return false;
  }
}

// The nonce of the request being rendered, for the router (src/router.tsx
// reads it through currentNonce()); the penetration test's finding 12.
const nonceStore = new AsyncLocalStorage<string>();
(globalThis as { __cloveCspNonce?: AsyncLocalStorage<string> }).__cloveCspNonce = nonceStore;

/**
 * What a browser would have refused under the policy, written to the Worker's
 * log and kept nowhere else. Capped, so it is no way to fill the log.
 */
async function cspReport(request: Request): Promise<Response> {
  const body = (await request.text()).slice(0, 4096);
  console.warn(`csp-report ${body.replace(/\s+/g, " ")}`);
  return new Response(null, { status: 204 });
}

/**
 * A page carries the full policy, report-only while what it would refuse is
 * read (it refuses nothing yet); the enforced Content-Security-Policy stays
 * frame-ancestors alone until then (src/lib/security-headers.ts).
 */
function withPolicy(response: Response, nonce: string): Response {
  if (!(response.headers.get("content-type") ?? "").includes("text/html")) return response;
  const headers = new Headers(response.headers);
  headers.set("Content-Security-Policy-Report-Only", contentSecurityPolicy(nonce, CSP_REPORT_PATH));
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export default {
  async fetch(request: Request, env: unknown, ctx: unknown) {
    try {
      if (request.method === "POST" && new URL(request.url).pathname === CSP_REPORT_PATH) {
        return withSecurityHeaders(await cspReport(request));
      }
      const handler = await getServerEntry();
      const nonce = newNonce();
      const response = withPolicy(
        await nonceStore.run(nonce, () => handler.fetch(request, env, ctx)),
        nonce,
      );
      // Every response the Worker renders carries the security headers (the
      // first penetration test, 14 October 2026); static files take them
      // from public/_headers.
      return withSecurityHeaders(await normalizeCatastrophicSsrResponse(response));
    } catch (error) {
      console.error(error);
      return withSecurityHeaders(
        new Response(renderErrorPage(), {
          status: 500,
          headers: { "content-type": "text/html; charset=utf-8" },
        }),
      );
    }
  },
};
