/**
 * Which Supabase project this page talks to, by the address it was opened at.
 *
 * On 6 October the owner moved the demonstration out of production into a
 * project of its own, Clove ERP Demo, served at demo.cloveerp.com by this same
 * application. One build, two databases: the page chooses by its host.
 *
 *   demo.cloveerp.com   the demonstration project, whatever the build was
 *                       given, so a build configured for production cannot
 *                       send a prospect's sign-in there.
 *   anywhere else       what it did before: the environment where it is set
 *                       (a local stack, a preview, the browser suite's stub),
 *                       otherwise production.
 *
 * Both publishable keys are public by design (src/lib/erp.ts says why for
 * production's): Supabase ships the key in every client bundle, and on these
 * projects it opens nothing by itself.
 *
 * Kept free of the client so it can be tested without one.
 */

/** Where the demonstration is. Production links here instead of making one. */
export const DEMO_HOST = "demo.cloveerp.com";
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
 * The project for a page opened at `host`, given what the build's environment
 * says. `host` is a hostname (no port), or null where there is no page: on
 * the server, and in tests that do not say.
 */
export function chooseBackend(
  host: string | null,
  env: { url?: string | undefined; key?: string | undefined },
): Backend {
  if (host !== null && host.toLowerCase() === DEMO_HOST) return DEMO_BACKEND;
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
