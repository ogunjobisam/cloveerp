import { createIsomorphicFn } from "@tanstack/react-start";

import {
  APEX_HOST,
  APEX_ORIGIN,
  chooseBackend,
  isPublicSiteHost,
  normalHost,
  pageHost,
} from "./backend";

/**
 * Whether the host a page was opened at is one this build knows, or one only
 * the directory can answer for (src/lib/backend.ts).
 *
 * Asked by the root route, so that the server and the browser agree on what
 * to show: on a directory host both show the connecting shell until the
 * directory has answered, and no screen is rendered on the server against a
 * project it does not have. The server reads the host the request was made
 * to; the browser reads its own. The first render's answer is the server's,
 * carried to the browser with the page.
 */
export type HostKind = "static" | "directory";

const env = {
  url: import.meta.env["VITE_SUPABASE_URL"] as string | undefined,
  key: import.meta.env["VITE_SUPABASE_PUBLISHABLE_KEY"] as string | undefined,
};

export function hostKindOf(host: string | null): HostKind {
  return chooseBackend(host, env) === null ? "directory" : "static";
}

/**
 * The host a request was made to, without its port: the request's own URL.
 *
 * The application is a Cloudflare Worker, and a Worker's request URL is the
 * address the visitor asked for, as the edge received it. x-forwarded-host is
 * not read: it was a proxy's word when Lovable served the application, and in
 * front of a Worker it is whatever the visitor chose to send. The Host header
 * is read only if the URL somehow names no host.
 */
export function requestHost(request: Request): string {
  let named = "";
  try {
    named = new URL(request.url).hostname;
  } catch {
    named = "";
  }
  if (named === "") named = (request.headers.get("host") ?? "").split(":")[0] ?? "";
  return named.trim().toLowerCase();
}

/** The host this page was opened at: the request's on the server, the page's own in the browser. */
export const requestPageHost = createIsomorphicFn()
  .server(async (): Promise<string | null> => {
    const { getRequest } = await import("@tanstack/react-start/server");
    const host = requestHost(getRequest());
    return host === "" ? null : host;
  })
  .client(async (): Promise<string | null> => pageHost());

/** What robots.txt says on the public site: what it has always said. */
export const PUBLIC_ROBOTS = [
  "User-agent: Googlebot",
  "Allow: /",
  "",
  "User-agent: Bingbot",
  "Allow: /",
  "",
  "User-agent: Twitterbot",
  "Allow: /",
  "",
  "User-agent: facebookexternalhit",
  "Allow: /",
  "",
  "User-agent: *",
  "Allow: /",
  "",
  `Sitemap: ${APEX_ORIGIN}/sitemap.xml`,
  "",
].join("\n");

/** What it says everywhere else: a client's door, the demonstration, a preview. */
export const CLOSED_ROBOTS = "User-agent: *\nDisallow: /\n";

/**
 * robots.txt for a host. Only the public site is offered to a crawler: a
 * client's host is its own organisation's sign-in, and the demonstration is a
 * copy of the product with nothing on it a search should find.
 */
export function robotsFor(host: string | null): string {
  return isPublicSiteHost(host) ? PUBLIC_ROBOTS : CLOSED_ROBOTS;
}

/**
 * Where the sitemap is, asked for at a host: null on the apex, which serves
 * it; the apex's address everywhere else, www included. A sitemap names pages
 * on its own host only, and the pages it lists are the apex's.
 */
export function sitemapRedirect(host: string | null): string | null {
  return host !== null && normalHost(host) === APEX_HOST ? null : `${APEX_ORIGIN}/sitemap.xml`;
}
