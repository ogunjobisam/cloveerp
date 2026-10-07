/**
 * The directory: which Supabase project a host belongs to.
 *
 * One Supabase project per client, one subdomain each (the owner's decision
 * of 7 October). The application is one build serving every host, and a page
 * opened at acme.cloveerp.com must learn which project to sign in to before
 * it talks to any. The control plane's register knows
 * (erp_meta.deployment, 20261011020000); the server route at
 * /api/directory/<host> asks it with the service client and answers the
 * browser with what is public by design: the code, the client's name, the
 * project's API URL and its publishable key.
 *
 * This file is the pure part — the shape of a host and of an answer — so that
 * the route and the browser read the same thing, and both are tested without
 * a server.
 */

export type DirectoryEntry = {
  code: string;
  client_name: string;
  url: string;
  key: string;
};

/** The longest host name the directory is asked about: DNS's own limit. */
export const HOST_MAX = 253;

/**
 * A host as the directory is asked about it: lower-case, without a port, and
 * shaped like a DNS name. Anything else is nobody's, before the register is
 * asked.
 */
export function directoryHost(raw: string | null | undefined): string | null {
  if (typeof raw !== "string") return null;
  const host = raw.trim().toLowerCase().split(":")[0] ?? "";
  if (host === "" || host.length > HOST_MAX) return null;
  if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(host)) return null;
  return host;
}

/**
 * What erp_deployment_for_host answered, read strictly: every field a string,
 * the URL https, or nothing at all. A half answer is no answer.
 */
export function readDirectoryEntry(answer: unknown): DirectoryEntry | null {
  if (answer === null || typeof answer !== "object") return null;
  const a = answer as Record<string, unknown>;
  const code = a["code"];
  const name = a["client_name"];
  const url = a["url"];
  const key = a["key"];
  if (typeof code !== "string" || typeof name !== "string") return null;
  if (typeof url !== "string" || !/^https:\/\/[a-z0-9.-]+$/.test(url)) return null;
  if (typeof key !== "string" || key === "") return null;
  return { code, client_name: name, url, key };
}
