import {
  createClient,
  FunctionsFetchError,
  FunctionsHttpError,
  FunctionsRelayError,
  type Session,
} from "@supabase/supabase-js";

import type {
  InviteRequest,
  InviteResponse,
  ResendRequest,
  ResendResponse,
} from "./invitation-email";

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
 * These are here rather than only in the environment because a build that
 * reads only the environment is a build that can arrive unconfigured, and one
 * did: the values lived in a tracked `.env` until it left version control, and
 * from then on every publish shipped an application whose first screen told the
 * visitor to set two variables. The application is published by hand from
 * Lovable and the values are inlined at build time, so nothing downstream could
 * repair it either.
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
 * The environment still wins where it is set, which is how a preview or a
 * second project is pointed elsewhere without touching the source.
 */
const DEFAULT_SUPABASE_URL = "https://xpzffnnhnhcqyjqcueja.supabase.co";
const DEFAULT_SUPABASE_PUBLISHABLE_KEY =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhwemZmbm5obmhjcXlqcWN1ZWphIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODgwMDIyNDIsImV4cCI6MjEwMzU3ODI0Mn0.PKnEUURM8CTNVkBjgA_pCoQJheGmL_6I7UD1-5Uywjk";

const url = (import.meta.env["VITE_SUPABASE_URL"] as string | undefined) || DEFAULT_SUPABASE_URL;
const key =
  (import.meta.env["VITE_SUPABASE_PUBLISHABLE_KEY"] as string | undefined) ||
  DEFAULT_SUPABASE_PUBLISHABLE_KEY;

/** The project this build talks to. Read these rather than the variables. */
export const supabaseUrl = url;
export const supabasePublishableKey = key;

export const isConfigured = Boolean(url && key);

export const supabase = isConfigured
  ? createClient(url, key, {
      auth: { persistSession: true, autoRefreshToken: true },
    })
  : null;

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
  const ref = url.match(/^https?:\/\/([^.]+)\./)?.[1];
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
  entities: ErpEntity[];
  sites: ErpSite[];
  permissions: string[];
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

export async function currentSession(): Promise<Session | null> {
  if (!supabase) return null;
  const { data } = await supabase.auth.getSession();
  return data.session;
}
