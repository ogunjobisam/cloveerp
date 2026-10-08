/**
 * Which Supabase project this page talks to, by the address it was opened at.
 *
 * On 6 October the owner moved the demonstration out of production into a
 * project of its own, Clove ERP Demo, served at demo.cloveerp.com by this same
 * application. On 7 October the owner decided that every client gets a
 * project of its own too, served at <code>.cloveerp.com by this same
 * application. One build, many databases: the page chooses by its host.
 *
 *   demo.cloveerp.com     the demonstration project, whatever the build was
 *                         given, so a build configured for production cannot
 *                         send a prospect's sign-in there.
 *   <code>.cloveerp.com   a client's own project, which this build does not
 *                         know: the page asks the directory on the control
 *                         plane (/api/directory/<host>, src/lib/erp.ts's
 *                         ensureBackend) and talks to nothing until it has
 *                         answered. NOTHING FALLS THROUGH TO PRODUCTION: a
 *                         subdomain nobody holds is nobody's, never
 *                         production's. That holds for every name under the
 *                         apex but the apex, www and the demonstration, not
 *                         only for one shaped like a code: ab.cloveerp.com,
 *                         a.b.cloveerp.com and acme.cloveerp.com. (with the
 *                         trailing dot of a fully qualified name) each ask the
 *                         directory too (isDirectoryHost), and the directory
 *                         says whether anybody is there.
 *   anywhere else         what it did before: the environment where it is set
 *                         (a local stack, a preview, the browser suite's stub),
 *                         otherwise production — the apex, www, and hosts
 *                         that are not under the apex at all.
 *
 * Both publishable keys here are public by design (src/lib/erp.ts says why for
 * production's): Supabase ships the key in every client bundle, and on these
 * projects it opens nothing by itself. A client's publishable key is public
 * the same way, and comes from the directory.
 *
 * Kept free of the client so it can be tested without one.
 */

/** The apex every deployment is served under. */
export const APEX_HOST = "cloveerp.com";
export const APEX_ORIGIN = `https://${APEX_HOST}`;

/** Where the demonstration is. Production links here instead of making one. */
export const DEMO_HOST = `demo.${APEX_HOST}`;
export const DEMO_ADDRESS = `https://${DEMO_HOST}`;

export type Backend = { url: string; key: string };

export const PRODUCTION_BACKEND: Backend = {
  url: "https://xpzffnnhnhcqyjqcueja.supabase.co",
  key: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhwemZmbm5obmhjcXlqcWN1ZWphIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODgwMDIyNDIsImV4cCI6MjEwMzU3ODI0Mn0.PKnEUURM8CTNVkBjgA_pCoQJheGmL_6I7UD1-5Uywjk",
};

export const DEMO_BACKEND: Backend = {
  url: "https://lhizhynckagmjbbpghxq.supabase.co",
  key: "sb_publishable_ArDJSV4iyrDSHttu-GIJeg_6qqF0XxJ",
};

/** The public site's other name. Served as the apex is. */
export const WWW_HOST = `www.${APEX_HOST}`;

/**
 * A host as it is compared here: trimmed, lower-case, and without the one
 * trailing dot a fully qualified name may carry, so acme.cloveerp.com. is
 * acme.cloveerp.com and not a host under some other name.
 */
export function normalHost(host: string): string {
  const h = host.trim().toLowerCase();
  return h.endsWith(".") ? h.slice(0, -1) : h;
}

/**
 * A host only the directory can answer for: any name under the apex that is
 * not the apex, www or the demonstration, whatever its shape. Fails closed: a
 * label too short to be a code (ab.cloveerp.com), a name two levels down
 * (a.b.cloveerp.com) or one a code could never be (-x.cloveerp.com) is asked
 * about like a client's, and the directory says nobody is there. None of them
 * ever reaches production, which is what the wildcard route serving every
 * subdomain would otherwise give them.
 */
export function isDirectoryHost(host: string | null): boolean {
  if (host === null) return false;
  const h = normalHost(host);
  if (h === DEMO_HOST || h === WWW_HOST) return false;
  return h.endsWith(`.${APEX_HOST}`);
}

/** The apex and www: the public site, and the only hosts a crawler is invited to. */
export function isPublicSiteHost(host: string | null): boolean {
  if (host === null) return false;
  const h = normalHost(host);
  return h === APEX_HOST || h === WWW_HOST;
}

/**
 * Whether the marketing pages are another host's: on the demonstration and on
 * every host the directory answers for, they are the apex's. The
 * demonstration's own copy of the enquiry form would post to the
 * demonstration's project, where nobody reads it, so it is not served there
 * either. Everywhere else (the apex, www, a preview, a local stack) they are
 * here.
 */
export function marketingIsElsewhere(host: string | null): boolean {
  if (host === null) return false;
  return normalHost(host) === DEMO_HOST || isDirectoryHost(host);
}

/** The pages that are the apex's: the product page and the enquiry form. */
export const APEX_PATHS: ReadonlySet<string> = new Set(["/product", "/contact"]);

/**
 * Where a link to one of the apex's pages goes from a page at `host`: the
 * apex's own address where the marketing pages are elsewhere, the path
 * itself everywhere else.
 */
export function apexHref(path: string, host: string | null): string {
  return marketingIsElsewhere(host) ? `${APEX_ORIGIN}${path}` : path;
}

/**
 * Where a page opened at `host` must go instead, or null to stay: one of the
 * apex's pages, asked for on a host whose marketing pages are elsewhere, is
 * the apex's page, with the same query. A trailing slash is the same page.
 */
export function apexRedirect(pathname: string, search: string, host: string | null): string | null {
  const path = pathname.replace(/\/+$/, "") || "/";
  if (!APEX_PATHS.has(path) || !marketingIsElsewhere(host)) return null;
  return `${APEX_ORIGIN}${path}${search}`;
}

/**
 * A client's host: one label under the apex that is neither the apex, www
 * nor the demonstration, shaped like a code. Only the directory knows whose
 * it is. Every such host is a directory host; not every directory host is
 * shaped like this (isDirectoryHost), and the choice of project goes by that
 * one.
 */
export function isClientHost(host: string | null): boolean {
  if (host === null) return false;
  const h = host.toLowerCase();
  if (h === DEMO_HOST || h === APEX_HOST || h === `www.${APEX_HOST}`) return false;
  const m = h.match(/^([a-z0-9][a-z0-9-]{1,61}[a-z0-9])\.(.+)$/);
  return m !== null && m[2] === APEX_HOST;
}

/** The code a client's host carries, or null for any other host. */
export function clientCodeOf(host: string | null): string | null {
  if (!isClientHost(host)) return null;
  return (host as string).toLowerCase().slice(0, -(APEX_HOST.length + 1));
}

/**
 * The project for a page opened at `host`, given what the build's environment
 * says; or null for a host only the directory can answer for. `host` is a
 * hostname (no port), or null where there is no page: on the server, and in
 * tests that do not say.
 */
export function chooseBackend(
  host: string | null,
  env: { url?: string | undefined; key?: string | undefined },
): Backend | null {
  if (host !== null && normalHost(host) === DEMO_HOST) return DEMO_BACKEND;
  if (isDirectoryHost(host)) return null;
  return {
    url: env.url || PRODUCTION_BACKEND.url,
    key: env.key || PRODUCTION_BACKEND.key,
  };
}

/** The hostname of the page this runs in, or null on the server. */
export function pageHost(): string | null {
  if (typeof window === "undefined") return null;
  try {
    return window.location.hostname || null;
  } catch {
    return null;
  }
}
