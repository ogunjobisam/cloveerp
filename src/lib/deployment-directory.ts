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
 *
 * Since 20261012020000 the register answers three ways for a host it holds,
 * because a client can be paused and can move:
 *
 *   a project    built, live or being offboarded: the project to talk to.
 *   suspended    the owner has suspended the client's service. Its project
 *                keeps running and keeps receiving releases (Supabase cannot
 *                pause a project on a paid plan), but its address is not
 *                served: no URL and no key are given, so no page can boot.
 *   moved        the host is an address the client was renamed from, within
 *                the ninety days it is kept: where the client is now.
 */

import { isDirectoryHost, normalHost } from "./backend";

/** A project to talk to: what a built, live or offboarding deployment answers. */
export type DirectoryProject = {
  code: string;
  client_name: string;
  url: string;
  key: string;
};

/** A deployment whose service is suspended: named, and nothing to talk to. */
export type DirectorySuspended = {
  code: string;
  client_name: string;
  suspended: true;
};

/** An address a deployment was renamed from, still kept: its new origin. */
export type DirectoryMoved = {
  code: string;
  client_name: string;
  moved_to: string;
};

/** Whatever the register answered for a host it holds. */
export type DirectoryEntry = DirectoryProject | DirectorySuspended | DirectoryMoved;

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
 * The last answer the browser kept, so a client's people reach their own
 * project while the control plane is briefly away: used when the directory
 * cannot answer (a 503, or no answer at all), forgotten when it answers 404.
 * A day.
 */
export const DIRECTORY_CACHE_TTL_MS = 24 * 60 * 60 * 1000;

/** Where a browser keeps the last answer for a host. */
export function cacheKey(host: string): string {
  return `cloveerp.backend:${host}`;
}

/** The answer as it is kept, with when it was kept. */
export function cachedEntryJson(entry: DirectoryEntry, now: number): string {
  return JSON.stringify({ ...entry, at: now });
}

/** A kept answer, read strictly and only while it is fresh. */
export function readCachedEntry(raw: string | null, now: number): DirectoryEntry | null {
  if (typeof raw !== "string" || raw === "") return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (parsed === null || typeof parsed !== "object") return null;
  const at = (parsed as Record<string, unknown>)["at"];
  if (typeof at !== "number" || !(now - at >= 0) || now - at > DIRECTORY_CACHE_TTL_MS) return null;
  return readDirectoryEntry(parsed);
}

/**
 * The origin a moved address names, read strictly: https, a host and nothing
 * else, and a host only the directory answers for (./backend.ts), so a moved
 * address can only ever send a person to another client's address under the
 * apex, never anywhere else.
 */
function movedOrigin(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const m = raw.match(
    /^https:\/\/([a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+)$/,
  );
  if (m === null || m[1] === undefined || !isDirectoryHost(m[1])) return null;
  return raw;
}

/**
 * What erp_deployment_for_host answered, read strictly, in one of its three
 * shapes or not at all. A half answer is no answer.
 *
 *   suspended  `suspended: true`, whatever else the answer carries: anything
 *              said about suspension other than true or false is no answer,
 *              and a URL or key beside it is dropped, so a suspended
 *              address can never boot a page.
 *   moved      `moved_to`, an https origin under the apex (movedOrigin); one
 *              that is not is no answer, never a project.
 *   a project  every field a string, the URL https, the key not empty.
 */
export function readDirectoryEntry(answer: unknown): DirectoryEntry | null {
  if (answer === null || typeof answer !== "object") return null;
  const a = answer as Record<string, unknown>;
  const code = a["code"];
  const name = a["client_name"];
  if (typeof code !== "string" || typeof name !== "string") return null;
  const suspended = a["suspended"];
  if (suspended !== undefined && suspended !== null && suspended !== false) {
    return suspended === true ? { code, client_name: name, suspended: true } : null;
  }
  const movedTo = a["moved_to"];
  if (movedTo !== undefined && movedTo !== null) {
    const to = movedOrigin(movedTo);
    return to === null ? null : { code, client_name: name, moved_to: to };
  }
  const url = a["url"];
  const key = a["key"];
  if (typeof url !== "string" || !/^https:\/\/[a-z0-9.-]+$/.test(url)) return null;
  if (typeof key !== "string" || key === "") return null;
  return { code, client_name: name, url, key };
}

/**
 * What the directory route answered the browser: its status, and its body
 * when it answered OK. Null when there was no answer at all: the request
 * failed or ran out of time.
 */
export type DirectoryResponse = { status: number; body: unknown };

/**
 * What the browser concludes about a host, because some answers look alike
 * and must never be confused.
 *
 *   found        the directory named the project; or it could not answer and
 *                a copy kept from an earlier answer is still fresh. `fresh`
 *                is true when the directory itself just answered, and the
 *                copy is to be kept again.
 *   suspended    the client's service is suspended: the page says so and
 *                boots nothing. Kept like a project, so a suspended client
 *                is not served from an older copy while the directory is
 *                away.
 *   moved        the host is an address the client has moved from: the page
 *                goes to the new one (movedHref). Kept the same way.
 *   none         the directory said nobody is at this host (404), or that it
 *                is not a host anybody could hold (400). Believed at once,
 *                and any copy kept for the host is to be forgotten.
 *   unreachable  the directory could not say (a 503, any other status, a
 *                half answer, a timeout, no network) and nothing fresh is
 *                kept. Not "nobody is here": the page says it could not find
 *                out, and offers to ask again.
 */
export type DirectoryOutcome =
  | { kind: "found"; entry: DirectoryProject; fresh: boolean }
  | { kind: "suspended"; entry: DirectorySuspended; fresh: boolean }
  | { kind: "moved"; entry: DirectoryMoved; fresh: boolean }
  | { kind: "none" }
  | { kind: "unreachable" };

function outcomeOf(entry: DirectoryEntry, fresh: boolean): DirectoryOutcome {
  if ("suspended" in entry) return { kind: "suspended", entry, fresh };
  if ("moved_to" in entry) return { kind: "moved", entry, fresh };
  return { kind: "found", entry, fresh };
}

export function directoryOutcome(
  response: DirectoryResponse | null,
  kept: DirectoryEntry | null,
): DirectoryOutcome {
  if (response !== null) {
    if (response.status === 404 || response.status === 400) return { kind: "none" };
    if (response.status >= 200 && response.status < 300) {
      const entry = readDirectoryEntry(response.body);
      if (entry) return outcomeOf(entry, true);
    }
  }
  return kept ? outcomeOf(kept, false) : { kind: "unreachable" };
}

/**
 * What the browser does with the copy it keeps for a host, after an outcome:
 * keep the directory's own answer, whichever of the three it is, in place of
 * whatever was kept, so a suspension or a move replaces a project kept from
 * before and an outage cannot bring that project back; forget it when nobody
 * is here; otherwise leave it as it is.
 */
export function keptCopyAfter(outcome: DirectoryOutcome): DirectoryEntry | "forget" | null {
  if (outcome.kind === "none") return "forget";
  if (outcome.kind === "unreachable" || !outcome.fresh) return null;
  return outcome.entry;
}

/** Where the page is, as much of it as a move keeps. */
export type PageLocation = { host: string; pathname: string; search: string; hash: string };

/**
 * Where a page opened at a moved address goes: the same path, query and
 * fragment at the client's new address, so a bookmark or a link in an email
 * still lands on its record. Null when the move would go nowhere new — the
 * new address is this one, or not an origin at all — which the register
 * never answers, and the page then stays where it is rather than send
 * itself round in a loop.
 */
export function movedHref(movedTo: string, here: PageLocation): string | null {
  let target: URL;
  try {
    target = new URL(movedTo);
  } catch {
    return null;
  }
  if (target.protocol !== "https:" || target.host === normalHost(here.host)) return null;
  const path = here.pathname.startsWith("/") ? here.pathname : `/${here.pathname}`;
  return `${target.origin}${path}${here.search}${here.hash}`;
}
