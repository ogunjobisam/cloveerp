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
 *                         production's.
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

/**
 * A client's host: one label under the apex that is neither the apex, www
 * nor the demonstration. Only the directory knows whose it is.
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
 * says; or null for a client's host, whose project only the directory knows.
 * `host` is a hostname (no port), or null where there is no page: on the
 * server, and in tests that do not say.
 */
export function chooseBackend(
  host: string | null,
  env: { url?: string | undefined; key?: string | undefined },
): Backend | null {
  if (host !== null && host.toLowerCase() === DEMO_HOST) return DEMO_BACKEND;
  if (isClientHost(host)) return null;
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
