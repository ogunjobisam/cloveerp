import type { SessionRole } from "./roles-label";
import {
  createClient,
  FunctionsFetchError,
  FunctionsHttpError,
  FunctionsRelayError,
  type Session,
} from "@supabase/supabase-js";

import type { SupabaseClient } from "@supabase/supabase-js";

import { chooseBackend, isClientHost, pageHost, type Backend } from "./backend";
import {
  cacheKey,
  cachedEntryJson,
  readCachedEntry,
  readDirectoryEntry,
  type DirectoryEntry,
} from "./deployment-directory";
import type {
  InviteRequest,
  InviteResponse,
  ResendRequest,
  ResendResponse,
} from "./invitation-email";
import {
  isDatabaseRequest,
  keepTabPersonaFor,
  readTabPersona,
  withActAs,
  writeTabPersona,
} from "./persona";

/**
 * The single point at which the front end touches the database.
 *
 * Everything below goes through `public.erp_*` functions rather than table
 * endpoints. That is deliberate: the `erp` schema is not exposed to PostgREST,
 * because exposing it would put roughly a hundred and twenty tables on the REST
 * surface at once. Row-level security would still hold — but "protected by RLS"
 * and "deliberately exposed" are different claims, and only the second is a
 * design.
 *
 * So reads come from a small curated API, and writes go through the functions
 * that already gate them (`erp.submit_command`, `erp.apply_stock_movement`,
 * `erp_ai.apply_proposal`), each of which authorises, validates and records.
 * There is no CRUD endpoint onto a table anywhere in this client, and that is
 * the point rather than an omission.
 */

/**
 * The project this build talks to when the host names no other.
 *
 * The values are in the source rather than only in the environment because a
 * build that reads only the environment is a build that can arrive
 * unconfigured, and one did: the values lived in a tracked `.env` until it left
 * version control, and from then on every publish shipped an application whose
 * first screen told the visitor to set two variables. The application is
 * published by hand from Lovable and the values are inlined at build time, so
 * nothing downstream could repair it either.
 *
 * The publishable key is public by design. Supabase ships it in the client
 * bundle of every application built on it — this one included, before and after
 * this change — and it is the key the browser presents on every request. On
 * this project it opens nothing on its own: `anon` holds EXECUTE on no function
 * in any product schema (`erp.assert_no_public_execute`), the `erp` schema is
 * not exposed to PostgREST at all, and every table is behind row-level
 * security. What it buys is that every build starts connected — Lovable's
 * publish, the build CI runs with no environment at all, a fresh clone, a fork.
 *
 * Since 6 October there are two projects, and the page's own address chooses
 * (./backend.ts): opened at demo.cloveerp.com it talks to the demonstration
 * project, whatever the build was given; anywhere else the environment still
 * wins where it is set, which is how a preview or a local stack is pointed
 * elsewhere without touching the source, and production otherwise.
 *
 * Since 7 October there are as many projects as clients, one each, served at
 * <code>.cloveerp.com. This build does not know them: opened at a client's
 * host it talks to nothing until the directory on the control plane
 * (/api/directory/<host>) has said which project, and the root route holds
 * the screens back until then (ensureBackend below). These are live bindings
 * for that reason: what the module exports is set the moment the project is
 * known, at load for every host this build knows and after the directory
 * answers for a client's, and every reader reads them at the moment it asks.
 */
const env = {
  url: import.meta.env["VITE_SUPABASE_URL"] as string | undefined,
  key: import.meta.env["VITE_SUPABASE_PUBLISHABLE_KEY"] as string | undefined,
};

/**
 * The project this page talks to. Read these rather than the variables. Empty
 * on a client's host until the directory has answered.
 */
export let supabaseUrl = "";
export let supabasePublishableKey = "";

export let isConfigured = false;

/**
 * This browser tab's own storage, where it keeps whom it acts as in a
 * demonstration. sessionStorage is per tab and ends with it, so another tab or
 * device of the same sign-in is never affected. Null on the server and where
 * storage is blocked: then the tab acts as the person who signed in.
 */
function tabStore(): Storage | null {
  if (typeof window === "undefined") return null;
  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

/** Whom this tab acts as in a demonstration, or null for the person who signed in. */
export function tabPersona(): string | null {
  return readTabPersona(tabStore());
}

/** The sign-in this tab holds, as the last auth event said. */
let signedInUser: string | null = null;

/** Keep whom this tab acts as, under the sign-in that chose her, or go back to yourself with null. */
export function setTabPersona(personaId: string | null): void {
  writeTabPersona(tabStore(), personaId, signedInUser);
}

/**
 * Every request this tab makes to the database names whom it acts as, read at
 * the moment it is sent. The database decides whether that stands
 * (erp.principal_context); a header naming anybody it may not is answered as
 * the person who signed in. Only the REST interface is sent it.
 */
const actAsFetch = (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
  const persona = tabPersona();
  if (!persona) return fetch(input, init);
  const target = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  if (!isDatabaseRequest(target, supabaseUrl)) return fetch(input, init);
  const headers = init?.headers ?? (input instanceof Request ? input.headers : undefined);
  return fetch(input, { ...init, headers: withActAs(headers, persona) });
};

export let supabase: SupabaseClient | null = null;

/** The project this page talks to, from here on. Once; a second project is a second page. */
function bootBackend(backend: Backend): void {
  if (supabase) return;
  supabaseUrl = backend.url;
  supabasePublishableKey = backend.key;
  isConfigured = Boolean(backend.url && backend.key);
  if (!isConfigured) return;
  supabase = createClient(backend.url, backend.key, {
    auth: { persistSession: true, autoRefreshToken: true },
    global: { fetch: actAsFetch as typeof fetch },
  });
  // Signing out ends the tab's choice, and so does a sign-in other than the
  // one that chose: whoever signs in next in this tab is themselves.
  if (typeof window !== "undefined") {
    supabase.auth.onAuthStateChange((event, session) => {
      signedInUser = event === "SIGNED_OUT" ? null : (session?.user.id ?? null);
      keepTabPersonaFor(tabStore(), signedInUser);
    });
  }
}

// Every host this build knows is connected at load, as it always was: the
// demonstration's, the apex, a preview, a local stack, the server. A client's
// host waits for the directory.
{
  const known = chooseBackend(pageHost(), env);
  if (known) bootBackend(known);
}

function localStore(): Storage | null {
  if (typeof window === "undefined") return null;
  try {
    return window.localStorage;
  } catch {
    return null;
  }
}

/**
 * The directory's answer for this host: asked on this page's own origin, so
 * it needs no cross-origin anything; kept for a day in this browser, so the
 * control plane being away for a moment does not stop a client's people
 * signing in; forgotten when the directory says nobody is here.
 */
async function lookupDirectory(host: string): Promise<DirectoryEntry | null> {
  const store = localStore();
  const kept = cacheKey(host);
  try {
    const response = await fetch(`/api/directory/${encodeURIComponent(host)}`, {
      headers: { accept: "application/json" },
    });
    if (response.status === 404) {
      try {
        store?.removeItem(kept);
      } catch {
        /* nothing kept, or nowhere to keep it */
      }
      return null;
    }
    if (response.ok) {
      const entry = readDirectoryEntry(await response.json());
      if (entry) {
        try {
          store?.setItem(kept, cachedEntryJson(entry, Date.now()));
        } catch {
          /* a private window, or site data blocked: the answer is still the answer */
        }
        return entry;
      }
    }
  } catch {
    /* the control plane could not be reached: the last answer, if it is fresh */
  }
  try {
    return readCachedEntry(store?.getItem(kept) ?? null, Date.now());
  } catch {
    return null;
  }
}

let directoryBoot: Promise<Backend | null> | null = null;

/**
 * The project this page talks to, once it is known: at once for every host
 * this build knows, after the directory has answered for a client's host, and
 * null for a client's host nobody holds. Asked once; every later call answers
 * the same. The root route asks it before it shows any screen on a client's
 * host, so no screen ever runs against no project.
 */
export function ensureBackend(): Promise<Backend | null> {
  if (supabase) return Promise.resolve({ url: supabaseUrl, key: supabasePublishableKey });
  const host = pageHost();
  if (host === null || !isClientHost(host)) return Promise.resolve(null);
  directoryBoot ??= lookupDirectory(host).then((entry) => {
    if (!entry) return null;
    const backend: Backend = { url: entry.url, key: entry.key };
    bootBackend(backend);
    return backend;
  });
  return directoryBoot;
}

/**
 * Whether this browser is holding a session, without waiting to ask.
 *
 * `supabase.auth.getSession()` is asynchronous, so the first paint cannot know
 * whether anybody is signed in; the root route needs to, because it shows the
 * product page to a visitor and the desk to a person who works here, and
 * flashing one before the other is worse than either. supabase-js persists the
 * session under a key derived from the project ref, so its presence is a good
 * enough hint to render against — and only a hint: the real check still runs
 * and still decides.
 *
 * False on the server, where there is no storage and no session, so the public
 * page is what gets rendered into the HTML.
 */
export function hasStoredSession(): boolean {
  if (typeof window === "undefined") return false;
  const ref = supabaseUrl.match(/^https?:\/\/([^.]+)\./)?.[1];
  if (!ref) return false;
  try {
    return Boolean(window.localStorage.getItem(`sb-${ref}-auth-token`));
  } catch {
    // A private window, or site data blocked. Treated as signed out: the
    // visitor sees the public page and can still sign in from it.
    return false;
  }
}

export type ErpEntity = { id: string; code: string; name: string };
export type ErpSite = { id: string; code: string; name: string; entity_id: string | null };

export type ErpSession = {
  principal_id: string | null;
  tenant_id: string | null;
  principal?: {
    display_name: string;
    given_name?: string | null;
    family_name?: string | null;
    email: string | null;
    kind: "person" | "service";
    user_locale: string | null;
    document_locale?: string | null;
    reporting_locale?: string | null;
    timezone: string | null;
  };
  tenant?: { code: string; name: string; status: string };
  /** The roles held here, administrator first; `support` when a support window granted it. */
  roles?: SessionRole[];
  entities: ErpEntity[];
  sites: ErpSite[];
  permissions: string[];
  /**
   * The modules installed and in force here, each once. Absent from a
   * database older than the site: then nothing is hidden, as before.
   */
  modules?: string[];
};

/**
 * An error from the database, with everything the database said.
 *
 * The engine raises `CLOVEERP_*` errors carrying a `hint` that is often the
 * next command to run — `erp.create_item` names `erp_create_uom`,
 * `guard_live_configuration` names `erp.promote_change_set`. Throwing only
 * `error.message` discarded all of it, which turned a refusal that explains
 * itself into one that does not.
 */
export class ErpError extends Error {
  readonly code: string | undefined;
  readonly details: string | undefined;
  readonly hint: string | undefined;

  constructor(
    message: string,
    parts: { code?: string | undefined; details?: string | undefined; hint?: string | undefined },
  ) {
    super(message);
    this.name = "ErpError";
    this.code = parts.code;
    this.details = parts.details;
    this.hint = parts.hint;
  }

  /**
   * The refusal token the engine leads its message with, verbatim.
   *
   * Verbatim rather than normalised, because friendlyError() strips this exact
   * substring out of the message before showing what is left. Two prefixes are
   * accepted for one release: 20260904980000 moved every refusal from ERPWARE_
   * to CLOVEERP_, and the database and this site are deployed separately and by
   * hand, so for a while whichever went first is ahead of the other.
   *
   * The character class includes digits. It did not, and four tokens carry one
   * — CLOVEERP_C1_SUITE_FAILED matched as far as the C, resolved to nothing,
   * and left "1_SUITE_FAILED: …" on the screen with the prefix stripped off.
   */
  get erpCode(): string | null {
    return /^((?:CLOVEERP|ERPWARE)_[A-Z0-9_]+)/.exec(this.message)?.[1] ?? null;
  }

  /**
   * 42501 is what `erp.authorise()` raises. Worth distinguishing because it is
   * the one failure a screen should treat as an answer rather than a fault:
   * the database decided, and it decided no.
   */
  get isPermissionDenied(): boolean {
    const token = this.erpCode;
    return (
      this.code === "42501" ||
      token === "CLOVEERP_PERMISSION_DENIED" ||
      token === "ERPWARE_PERMISSION_DENIED"
    );
  }
}

/**
 * Calling a `public.erp_*` function.
 *
 * Errors are surfaced rather than swallowed. A screen that renders empty when
 * the call failed is indistinguishable from one where there is genuinely
 * nothing to show, and the difference matters most exactly when something is
 * wrong.
 */
export async function callErp<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  if (!supabase) {
    throw new Error(
      "Supabase is not configured. Set VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY.",
    );
  }

  const { data, error } = await supabase.rpc(fn, args);

  if (error) {
    // PostgREST reports a missing function as PGRST202. Worth naming, because
    // the likeliest cause is the migrations not having been applied to the
    // project this build is pointed at — which is a deployment problem, not a
    // code one, and says so.
    if (error.code === "PGRST202") {
      throw new ErpError(
        `${fn} does not exist on this project. The Clove ERP migrations may not have been applied to it.`,
        { code: error.code },
      );
    }
    throw new ErpError(error.message, {
      code: error.code,
      details: error.details ?? undefined,
      hint: error.hint ?? undefined,
    });
  }

  return data as T;
}

/**
 * The invite function certainly did not run, so nothing it would have done was
 * done.
 *
 * Only one answer proves that: the platform itself replying 404 or 503 — a
 * function not deployed, or one that did not start — which it does without the
 * function's own `error` field. The screen may then make the invitation through
 * the door directly, as it did before email existed, and show the link to copy
 * with the reason it was not sent.
 */
export class InviteNotRun extends Error {
  constructor(message: string) {
    super(message);
    this.name = "InviteNotRun";
  }
}

/**
 * The request to the invite function failed on the way, so nobody here can say
 * whether it ran.
 *
 * A network failure or a relay error can arrive after the function has already
 * called the door and sent the email. Calling the door again then does harm:
 * erp_invite_principal supersedes the emailed token, so the person invited
 * holds a dead link, and erp_platform_onboard_company refuses the second
 * attempt because the organisation now exists. So this is never retried on its
 * own — the screen says what may have happened, and a person decides.
 *
 * friendlyError() reads `title` and `body`; `detail` is what supabase-js said.
 */
export class InviteOutcomeUnknown extends Error {
  readonly title = "Could not reach the invitation service.";
  readonly body =
    "The invitation may already have been created and emailed, so check the list before trying again.";
  readonly detail: string | null;

  constructor(detail?: string | null) {
    super(
      "Could not reach the invitation service. The invitation may already have been created and emailed, so check the list before trying again.",
    );
    this.name = "InviteOutcomeUnknown";
    this.detail = detail || null;
  }
}

/**
 * What a failed call to the invite function means, as one of the errors above.
 *
 *   FunctionsFetchError, FunctionsRelayError   InviteOutcomeUnknown
 *   404 or 503 without the function's `error`  InviteNotRun
 *   anything the function said                 ErpError, in its words
 *
 * Anything the function itself said must not be retried by calling the door
 * directly either: the function may already have made the invitation.
 */
export async function inviteFailure(error: unknown): Promise<unknown> {
  if (error instanceof FunctionsFetchError || error instanceof FunctionsRelayError) {
    return new InviteOutcomeUnknown(error.message);
  }

  if (error instanceof FunctionsHttpError) {
    const response = error.context as Response;
    let said: Record<string, unknown> = {};
    try {
      const parsed: unknown = await response.json();
      if (typeof parsed === "object" && parsed !== null) said = parsed as Record<string, unknown>;
    } catch {
      /* not JSON: not the function speaking */
    }
    const message = said["error"];
    if (typeof message !== "string" && (response.status === 404 || response.status === 503)) {
      return new InviteNotRun("The email service for this site is not available yet");
    }
    const code = said["code"];
    const hint = said["hint"];
    return new ErpError(
      typeof message === "string" && message !== ""
        ? message
        : `The invitation could not be sent (the email service answered ${response.status}).`,
      {
        code: typeof code === "string" ? code : undefined,
        hint: typeof hint === "string" ? hint : undefined,
      },
    );
  }

  return error;
}

/**
 * Calling an Edge Function that works on a person's behalf: document output,
 * a commercial document's link, a supplier's answer. In the project this page
 * talks to, which since 7 October may be a client's own (src/lib/backend.ts).
 *
 * functions.invoke rather than a hand-built fetch, for the reason callInvite
 * gives. A refusal comes back as the function's JSON — the database's own
 * message, code and hint — and is thrown as an ErpError, so friendlyError()
 * reads it exactly as it reads a callErp refusal. A function that could not
 * be reached, or that is not deployed yet, is an ErpError too, worded for
 * the person rather than the log.
 */
export async function callFunction<T>(name: string, body: Record<string, unknown>): Promise<T> {
  if (!supabase) {
    throw new Error(
      "Supabase is not configured. Set VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY.",
    );
  }
  const { data, error } = await supabase.functions.invoke(name, { body });
  if (!error) return data as T;
  throw await functionFailure(error, name);
}

async function functionFailure(error: unknown, name: string): Promise<unknown> {
  if (error instanceof FunctionsFetchError || error instanceof FunctionsRelayError) {
    return new ErpError("Could not reach the server. Check the connection and try again.", {
      details: error.message,
    });
  }
  if (error instanceof FunctionsHttpError) {
    const response = error.context as Response;
    let said: Record<string, unknown> = {};
    try {
      const parsed: unknown = await response.json();
      if (typeof parsed === "object" && parsed !== null) said = parsed as Record<string, unknown>;
    } catch {
      /* not JSON: not the function speaking */
    }
    const message = said["error"];
    if (typeof message !== "string" && (response.status === 404 || response.status === 503)) {
      return new ErpError(
        `This part of the service (${name}) is not available on this deployment yet.`,
        { code: "CLOVEERP_FUNCTION_NOT_DEPLOYED" },
      );
    }
    const code = said["code"];
    const hint = said["hint"];
    return new ErpError(
      typeof message === "string" && message !== ""
        ? message
        : `The request could not be completed (the service answered ${response.status}).`,
      {
        code: typeof code === "string" ? code : undefined,
        hint: typeof hint === "string" ? hint : undefined,
      },
    );
  }
  return error;
}

/**
 * Calling supabase/functions/invite.
 *
 * functions.invoke rather than a hand-built fetch, because it attaches what the
 * function checks — the session's bearer token, the apikey, and the client
 * header the function's preflight allows.
 *
 * A refusal comes back as an ErpError built from the function's JSON, which
 * carries the database's own message, code and hint, so friendlyError() and
 * isPermissionDenied read it exactly as they read a callErp refusal. Every
 * other failure is sorted by inviteFailure() above.
 */
export async function callInvite(body: InviteRequest): Promise<InviteResponse>;
export async function callInvite(body: ResendRequest): Promise<ResendResponse>;
export async function callInvite(
  body: InviteRequest | ResendRequest,
): Promise<InviteResponse | ResendResponse> {
  if (!supabase) {
    throw new Error(
      "Supabase is not configured. Set VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY.",
    );
  }

  const { data, error } = await supabase.functions.invoke("invite", { body });
  if (!error) return data as InviteResponse | ResendResponse;
  throw await inviteFailure(error);
}

export const emptySession: ErpSession = {
  principal_id: null,
  tenant_id: null,
  entities: [],
  sites: [],
  permissions: [],
};

/**
 * Whether the session holds a permission. Given a list, whether it holds any
 * of them: the scanner opens for inventory.scan or inventory.move alike, and
 * the database decides the rest.
 */
export function hasPermission(
  session: ErpSession | null,
  code: string | readonly string[],
): boolean {
  const held = session?.permissions;
  if (!held) return false;
  return typeof code === "string" ? held.includes(code) : code.some((c) => held.includes(c));
}

/**
 * Whether the organisation has installed a module and the install is in force.
 *
 * A session that does not say (a database older than the site) hides nothing.
 * This decides what the desk offers; the database refuses a module's verbs
 * until it is installed whatever the desk shows.
 */
export function hasModule(session: ErpSession | null, code: string): boolean {
  const held = session?.modules;
  return held === undefined ? true : held.includes(code);
}

export async function currentSession(): Promise<Session | null> {
  if (!supabase) return null;
  const { data } = await supabase.auth.getSession();
  return data.session;
}
